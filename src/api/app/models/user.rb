require 'kconv'
require 'api_error'

class User < ApplicationRecord
  include CanRenderModel

  # Keep in sync with states defined in db/schema.rb
  STATES = ['unconfirmed', 'confirmed', 'locked', 'deleted', 'subaccount'].freeze
  NOBODY_LOGIN = '_nobody_'.freeze

  # disable validations because there can be users which don't have a bcrypt
  # password yet. this is for backwards compatibility
  has_secure_password validations: false

  has_many :watched_projects, dependent: :destroy, inverse_of: :user
  has_many :groups_users, inverse_of: :user
  has_many :roles_users, inverse_of: :user
  has_many :relationships, inverse_of: :user, dependent: :destroy

  has_many :comments, dependent: :destroy, inverse_of: :user
  has_many :status_messages
  has_many :messages
  has_many :tokens, class_name: 'Token', dependent: :destroy, inverse_of: :user
  has_one :rss_token, class_name: 'Token::Rss', dependent: :destroy

  has_many :reviews, dependent: :nullify

  has_many :event_subscriptions, inverse_of: :user

  belongs_to :owner, class_name: 'User'
  has_many :subaccounts, class_name: 'User', foreign_key: 'owner_id'

  has_many :requests_created, foreign_key: 'creator', primary_key: :login, class_name: 'BsRequest'

  # users have a n:m relation to group
  has_and_belongs_to_many :groups, -> { distinct }
  # users have a n:m relation to roles
  has_and_belongs_to_many :roles, -> { distinct }
  # users have 0..1 user_registration records assigned to them
  has_one :user_registration

  has_one :ec2_configuration, class_name: 'Cloud::Ec2::Configuration', dependent: :destroy
  has_one :azure_configuration, class_name: 'Cloud::Azure::Configuration', dependent: :destroy
  has_many :upload_jobs, class_name: 'Cloud::User::UploadJob', dependent: :destroy

  has_many :notifications, -> { order(created_at: :desc) }, as: :subscriber, dependent: :destroy

  has_many :saved_replies, -> { order(created_at: :desc) }, dependent: :destroy

  has_many :commit_activities

  has_many :status_message_acknowledgements, dependent: :destroy
  has_many :acknowledged_status_messages, through: :status_message_acknowledgements, class_name: 'StatusMessage', source: 'status_message'

  scope :confirmed, -> { where(state: 'confirmed') }
  scope :all_without_nobody, -> { where.not(login: NOBODY_LOGIN) }
  scope :not_deleted, -> { where.not(state: 'deleted') }
  scope :not_locked, -> { where.not(state: 'locked') }
  scope :with_login_prefix, ->(prefix) { where('login LIKE ?', "#{prefix}%") }
  scope :active, -> { confirmed.or(User.unscoped.where(state: :subaccount, owner: User.unscoped.confirmed)) }
  scope :staff, -> { joins(:roles).where('roles.title = ?', 'Staff') }
  scope :not_staff, -> { where.not(id: User.unscoped.staff.pluck(:id)) }
  scope :admins, -> { joins(:roles).where('roles.title = ?', 'Admin') }

  scope :in_beta, -> { where(in_beta: true) }
  scope :in_rollout, -> { where(in_rollout: true) }

  scope :list, lambda {
    all_without_nobody.includes(:owner).select(:id, :login, :email, :state, :realname, :owner_id, :updated_at, :ignore_auth_services)
  }

  scope :with_email, -> { where.not(email: [nil, '']) }

  scope :recently_seen, -> { where('last_logged_in_at > ?', 3.months.ago) }

  validates :login, :state, presence: { message: 'must be given' }

  validates :login,
            uniqueness: { case_sensitive: true, message: 'is the name of an already existing user' }

  validates :login,
            format: { with: /\A[\w $\^\-.#*+&'"]*\z/,
                      message: 'must not contain invalid characters' }
  validates :login,
            length: { in: 2..100, allow_nil: true,
                      too_long: 'must have less than 100 characters',
                      too_short: 'must have more than two characters' }

  validates :state, inclusion: { in: STATES }

  validate :validate_state

  # We want a valid email address. Note that the checking done here is very
  # rough. Email adresses are hard to validate now domain names may include
  # language specific characters and user names can be about anything anyway.
  # However, this is not *so* bad since users have to answer on their email
  # to confirm their registration.
  validates :email,
            format: { with: /\A([\w\-.\#$%&!?*'+=(){}|~]+)@([0-9a-zA-Z\-.\#$%&!?*'=(){}|~]+)+\z/,
                      message: 'must be a valid email address',
                      allow_blank: true }

  # we disabled has_secure_password's validations. therefore we need to do manual validations
  validate :password_validation
  validates :password, length: { minimum: 6, maximum: ActiveModel::SecurePassword::MAX_PASSWORD_LENGTH_ALLOWED }, allow_nil: true
  validates :password, confirmation: true, allow_blank: true

  before_save :send_metric_for_beta_change, if: :in_beta_changed?
  after_create :create_home_project, :track_create

  alias flipper_id id

  def track_create
    RabbitmqBus.send_to_bus('metrics', 'user.create value=1')
  end

  def create_home_project
    # avoid errors during seeding
    return if login.in?([NOBODY_LOGIN, 'Admin'])
    # may be disabled via Configuration setting
    return unless can_create_project?(home_project_name)

    # find or create the project
    project = Project.find_by(name: home_project_name)
    return if project

    project = Project.create!(name: home_project_name)
    project.commit_user = self
    # make the user maintainer
    project.relationships.create!(user: self, role: Role.find_by_title('maintainer'))
    project.store
    @home_project = project
  end

  # Inform ActiveModel::Dirty that changes are persistent now
  after_save :changes_applied

  # When a record object is initialized, we set the state and the login failure
  # count to unconfirmed/0 when it has not been set yet.
  before_validation(on: :create) do
    self.state ||= 'unconfirmed'

    # Set the last login time etc. when the record is created at first.
    self.last_logged_in_at = Time.zone.today

    self.login_failure_count = 0 if login_failure_count.nil?
  end

  def self.autocomplete_token(prefix = '')
    autocomplete_login(prefix).collect { |user| { name: user } }
  end

  def self.autocomplete_login(prefix = '')
    with_login_prefix(prefix).not_deleted.not_locked.limit(50).order(:login).pluck(:login)
  end

  # the default state of a user based on the api configuration
  def self.default_user_state
    ::Configuration.registration == 'confirmation' ? 'unconfirmed' : 'confirmed'
  end

  def self.create_user_with_fake_pw!(attributes = {})
    create!(attributes.merge(password: SecureRandom.base64(48)))
  end

  def self.create_ldap_user(attributes = {})
    user = create_user_with_fake_pw!(attributes.merge(state: default_user_state, adminnote: 'User created via LDAP'))

    return user if user.errors.empty?

    logger.info("Cannot create ldap userid: '#{login}' on OBS. Full log: #{user.errors.full_messages.to_sentence}")
    nil
  end

  # This static method tries to find a user with the given login and password
  # in the database. Returns the user or nil if he could not be found
  def self.find_with_credentials(login, password)
    return find_with_credentials_via_ldap(login, password) if CONFIG['ldap_mode'] == :on

    user = find_by_login(login)
    user.try(:authenticate_via_password, password)
  end

  def self.find_with_credentials_via_ldap(login, password)
    user = find_by_login(login)
    ldap_info = nil

    return user.authenticate_via_password(password) if user.try(:ignore_auth_services?)

    if CONFIG['ldap_mode'] == :on
      begin
        require 'ldap'
        logger.debug("Using LDAP to find #{login}")
        ldap_info = UserLdapStrategy.find_with_ldap(login, password)
      rescue LoadError
        logger.warn "ldap_mode selected but 'ruby-ldap' module not installed."
      rescue StandardError
        logger.debug "#{login} not found in LDAP."
      end
    end

    return unless ldap_info

    # We've found an ldap authenticated user - find or create an OBS userDB entry.
    if user
      # Check for ldap updates
      user.assign_attributes(email: ldap_info[0], realname: ldap_info[1])
      user.save if user.changed?
    else
      logger.debug('No user found in database, creating')
      logger.debug("Email: #{ldap_info[0]}")
      logger.debug("Name : #{ldap_info[1]}")

      user = create_ldap_user(login: login, email: ldap_info[0], realname: ldap_info[1])
    end

    user.mark_login!
    user
  end

  # Currently logged in user or nobody user if there is no user logged in.
  # Use this to check permissions, but don't treat it as logged in user. Check
  # is_nobody? on the returned object
  def self.possibly_nobody
    current || nobody
  end

  # Currently logged in user. Will thrown an exception if no user is logged in.
  # So the controller needs to require login if using this (or models using it)
  def self.session!
    raise ArgumentError, 'Requiring user, but found nobody' unless session

    current
  end

  # Currently logged in user or nil
  def self.session
    current if current && !current.is_nobody?
  end

  def self.admin_session?
    current && current.is_admin?
  end

  # set the user as current session user (should be real user)
  def self.session=(user)
    Thread.current[:user] = user
  end

  def self.get_default_admin
    admin = CONFIG['default_admin'] || 'Admin'
    user = User.find_by_login(admin)
    raise NotFoundError, "Admin not found, user #{admin} has not admin permissions" unless user.is_admin?

    user
  end

  def self.find_nobody!
    User.create_with(email: 'nobody@localhost',
                     realname: 'Anonymous User',
                     state: 'locked',
                     password: '123456').find_or_create_by(login: NOBODY_LOGIN)
  end

  def self.find_by_login!(login)
    user = not_deleted.find_by(login: login)
    return user if user

    raise NotFoundError, "Couldn't find User with login = #{login}"
  end

  # some users have last_logged_in_at empty
  def last_logged_in_at
    self[:last_logged_in_at] || created_at
  end

  def away?
    last_logged_in_at < 3.months.ago
  end

  def authenticate_via_password(password)
    if authenticate(password)
      mark_login!
      self
    else
      count_login_failure
      nil
    end
  end

  def validate_state
    # check that the state transition is valid
    errors.add(:state, 'must be a valid new state from the current state') unless state_transition_allowed?(state_was, state)
  end

  # This method returns true if the user is assigned the role with one of the
  # role titles given as parameters. False otherwise.
  def has_role?(*role_titles)
    obj = all_roles.detect do |role|
      role_titles.include?(role.title)
    end

    !obj.nil?
  end

  # This method creates a new registration token for the current user. Raises
  # a MultipleRegistrationTokens Exception if the user already has a
  # registration token assigned to him.
  #
  # Use this method instead of creating user_registration objects directly!
  def create_user_registration
    raise unless user_registration.nil?

    token = UserRegistration.new
    self.user_registration = token
  end

  # This method checks whether the given value equals the password when
  # hashed with this user's password hash type. Returns a boolean.
  def deprecated_password_equals?(value)
    hash_string(value) == deprecated_password
  end

  def authenticate(unencrypted_password)
    # for users without a bcrypt password we need an extra check and convert
    # the password to a bcrypt one
    if deprecated_password
      if deprecated_password_equals?(unencrypted_password)
        update(password: unencrypted_password, deprecated_password: nil, deprecated_password_salt: nil, deprecated_password_hash_type: nil)
        return self
      end

      return false
    end

    # it seems that the user is not using a deprecated password so we use bcrypt's
    # #authenticate method
    super
  end

  # Returns true if the the state transition from "from" state to "to" state
  # is valid. Returns false otherwise.
  #
  # Note that currently no permission checking is included here; It does not
  # matter what permissions the currently logged in user has, only that the
  # state transition is legal in principle.
  def state_transition_allowed?(from, to)
    from = from.to_i
    to = to.to_i

    return true if from == to # allow keeping state

    case from
    when 'unconfirmed'
      true
    when 'confirmed'
      to.in?(['locked', 'deleted'])
    when 'locked'
      to.in?(['confirmed', 'deleted'])
    when 'deleted'
      to == 'confirmed'
    else
      false
    end
  end

  def cloud_configurations?
    ec2_configuration.present? || azure_configuration.present?
  end

  def to_axml(_opts = {})
    render_axml
  end

  def render_axml(watchlist = false)
    # CanRenderModel
    render_xml(watchlist: watchlist)
  end

  def home_project_name
    "home:#{login}"
  end

  def home_project
    @home_project ||= Project.find_by(name: home_project_name)
  end

  def branch_project_name(branch)
    "#{home_project_name}:branches:#{branch}"
  end

  #####################
  # permission checks #
  #####################

  def is_admin?
    return @is_admin unless @is_admin.nil?

    @is_admin = roles.exists?(title: 'Admin')
  end

  def is_staff?
    return @is_staff unless @is_staff.nil?

    @is_staff = roles.exists?(title: 'Staff')
  end

  def is_nobody?
    login == NOBODY_LOGIN
  end

  def is_active?
    return owner.is_active? if owner

    self.state == 'confirmed'
  end

  def is_in_group?(group)
    case group
    when String
      group = Group.find_by_title(group)
    when Integer
      group = Group.find(group)
    when Group, nil
      nil
    else
      raise ArgumentError, "illegal parameter type to User#is_in_group?: #{group.class}"
    end

    group && lookup_strategy.is_in_group?(self, group)
  end

  # This method returns true if the user is granted the permission with one
  # of the given permission titles.
  def has_global_permission?(perm_string)
    logger.debug "has_global_permission? #{perm_string}"
    roles.detect do |role|
      return true if role.static_permissions.find_by(title: perm_string)
    end
  end

  # FIXME: This should be a policy
  def can_modify?(object, ignore_lock = nil)
    case object
    when Project
      can_modify_project?(object, ignore_lock)
    when Package
      can_modify_package?(object, ignore_lock)
    when nil
      false
    else
      raise ArgumentError, "Wrong type of object: '#{object.class}' instead of Project or Package."
    end
  end

  # FIXME: This should be a policy
  # project is instance of Project
  def can_modify_project?(project, ignore_lock = nil)
    raise ArgumentError, "illegal parameter type to User#can_modify_project?: #{project.class.name}" unless project.is_a?(Project)

    if project.new_record?
      # Project.check_write_access(!) should have been used?
      raise NotFoundError, 'Project is not stored yet'
    end

    can_modify_project_internal(project, ignore_lock)
  end

  # FIXME: This should be a policy
  # package is instance of Package
  def can_modify_package?(package, ignore_lock = nil)
    return false if package.nil? # happens with remote packages easily
    raise ArgumentError, "illegal parameter type to User#can_modify_package?: #{package.class.name}" unless package.is_a?(Package)
    return false if !ignore_lock && package.is_locked?
    return true if is_admin?
    return true if has_global_permission?('change_package')
    return true if has_local_permission?('change_package', package)

    false
  end

  # FIXME: This should be a policy
  def can_modify_user?(user)
    is_admin? || self == user
  end

  # FIXME: This should be a policy
  # project_name is name of the project
  def can_create_project?(project_name)
    ## special handling for home projects
    return true if project_name == home_project_name && Configuration.allow_user_to_create_home_project
    return true if /^#{home_project_name}:/ =~ project_name && Configuration.allow_user_to_create_home_project

    return true if has_global_permission?('create_project')

    parent_project = Project.new(name: project_name).parent
    return false if parent_project.nil?
    return true  if is_admin?

    has_local_permission?('create_project', parent_project)
  end

  # FIXME: This should be a policy
  def can_modify_attribute_definition?(object)
    can_create_attribute_definition?(object)
  end

  def attribute_modifier_rule_matches?(rule)
    return false if rule.user && rule.user != self
    return false if rule.group && !is_in_group?(rule.group)

    true
  end

  # FIXME: This should be a policy
  def can_create_attribute_definition?(object)
    object = object.attrib_namespace if object.is_a?(AttribType)
    raise ArgumentError, "illegal parameter type to User#can_change?: #{object.class.name}" unless object.is_a?(AttribNamespace)

    return true if is_admin?

    abies = object.attrib_namespace_modifiable_bies.includes([:user, :group])
    abies.any? { |rule| attribute_modifier_rule_matches?(rule) }
  end

  def attribute_modification_rule_matches?(rule, object)
    return false unless attribute_modifier_rule_matches?(rule)
    return false if rule.role && !has_local_role?(rule.role, object)

    true
  end

  # FIXME: This should be a policy
  def can_create_attribute_in?(object, atype)
    raise ArgumentError, "illegal parameter type to User#can_change?: #{object.class.name}" if !object.is_a?(Project) && !object.is_a?(Package)

    return true if is_admin?

    abies = atype.attrib_type_modifiable_bies.includes([:user, :group, :role])
    # no rules -> maintainer
    return can_modify?(object) if abies.empty?

    abies.any? { |rule| attribute_modification_rule_matches?(rule, object) }
  end

  # FIXME: This should be a policy
  def can_download_binaries?(package)
    can?(:download_binaries, package)
  end

  # FIXME: This should be a policy
  def can_source_access?(package)
    can?(:source_access, package)
  end

  # FIXME: This should be a policy
  def can?(key, package)
    is_admin? ||
      has_global_permission?(key.to_s) ||
      has_local_permission?(key.to_s, package)
  end

  def has_local_role?(role, object)
    if object.is_a?(Package) || object.is_a?(Project)
      logger.debug "running local role package check: user #{login}, package #{object.name}, role '#{role.title}'"
      rels = object.relationships.where(role_id: role.id, user_id: id)
      return true if rels.exists?

      rels = object.relationships.joins(:groups_users).where(groups_users: { user_id: id }).where(role_id: role.id)
      return true if rels.exists?

      return true if lookup_strategy.local_role_check(role, object)
    end

    return has_local_role?(role, object.project) if object.is_a?(Package)

    false
  end

  # local permission check
  # if context is a package, check permissions in package, then if needed continue with project check
  # if context is a project, check it, then if needed go down through all namespaces until hitting the root
  # return false if none of the checks succeed
  def has_local_permission?(perm_string, object)
    roles = Role.ids_with_permission(perm_string)
    return false unless roles

    parent = nil
    case object
    when Package
      logger.debug "running local permission check: user #{login}, package #{object.name}, permission '#{perm_string}'"
      # check permission for given package
      parent = object.project
    when Project
      logger.debug "running local permission check: user #{login}, project #{object.name}, permission '#{perm_string}'"
      # check permission for given project
      parent = object.parent
    when nil
      return has_global_permission?(perm_string)
    else
      return false
    end
    rel = object.relationships.where(user_id: id).where('role_id in (?)', roles)
    return true if rel.exists?

    rel = object.relationships.joins(:groups_users).where(groups_users: { user_id: id }).where('role_id in (?)', roles)
    return true if rel.exists?

    return true if lookup_strategy.local_permission_check(roles, object)

    if parent
      # check permission of parent project
      logger.debug "permission not found, trying parent project '#{parent.name}'"
      return has_local_permission?(perm_string, parent)
    end

    false
  end

  def lock!
    self.state = 'locked'
    save!

    # lock also all home projects to avoid unneccessary builds
    Project.where('name like ?', "#{home_project_name}%").find_each do |prj|
      next if prj.is_locked?

      prj.lock('User account got locked')
    end
  end

  def delete
    delete!
  rescue ActiveRecord::RecordInvalid
    false
  end

  def delete!
    # remove user data as much as possible
    # but we must NOT remove the information that the account did exist
    # or another user could take over the identity which can open security
    # issues (other infrastructur and systems using repositories)

    self.email = ''
    self.realname = ''
    self.state = 'deleted'
    save!

    # wipe also all home projects
    Project.where('name LIKE ?', "#{home_project_name}:%").or(Project.where(name: home_project_name)).each do |project|
      project.commit_opts = { comment: 'User account got deleted' }
      project.destroy
    end

    RabbitmqBus.send_to_bus('metrics', 'user.delete value=1') unless state_before_last_save == 'deleted'
    true
  end

  def involved_projects
    Project.for_user(id).or(Project.for_group(group_ids))
  end

  # lists packages maintained by this user and are not in maintained projects
  def involved_packages
    Package.for_user(id).or(Package.for_group(group_ids)).where.not(project: involved_projects)
  end

  # list packages owned by this user.
  def owned_packages
    owned = []
    begin
      OwnerSearch::Owned.new.for(self).each do |owner|
        owned << [owner.package, owner.project]
      end
    rescue APIError # no attribute set
    end
    owned
  end

  # lists reviews involving this user
  def involved_reviews(search = nil)
    result = BsRequest.by_user_reviews(id).or(
      BsRequest.by_project_reviews(involved_projects).or(
        BsRequest.by_package_reviews(involved_packages).or(
          BsRequest.by_group_reviews(groups)
        )
      )
    ).with_actions_and_reviews.where(state: :review, reviews: { state: :new }).where.not(creator: login)
    search.present? ? result.do_search(search) : result
  end

  # list requests involving this user
  def declined_requests(search = nil)
    result = requests_created.in_states(:declined).with_actions
    search.present? ? result.do_search(search) : result
  end

  # list incoming requests involving this user
  def incoming_requests(search = nil)
    result = BsRequest.where(id: BsRequestAction.bs_request_ids_of_involved_projects(involved_projects)).or(
      BsRequest.where(id: BsRequestAction.bs_request_ids_of_involved_packages(involved_packages))
    ).with_actions.in_states(:new)

    search.present? ? result.do_search(search) : result
  end

  # list outgoing requests involving this user
  def outgoing_requests(search = nil)
    result = requests_created.in_states([:new, :review]).with_actions
    search.present? ? result.do_search(search) : result
  end

  # list of all requests
  def requests(search = nil)
    project_ids = involved_projects
    package_ids = involved_packages

    actions = BsRequestAction.bs_request_ids_of_involved_projects(project_ids).or(
      BsRequestAction.bs_request_ids_of_involved_packages(package_ids)
    )

    reviews = Review.bs_request_ids_of_involved_users(id).or(
      Review.bs_request_ids_of_involved_projects(project_ids).or(
        Review.bs_request_ids_of_involved_packages(package_ids).or(
          Review.bs_request_ids_of_involved_groups(groups)
        )
      )
    ).where(state: :new)

    result = BsRequest.where(creator: login).or(
      BsRequest.where(id: actions).or(
        BsRequest.where(id: reviews)
      )
    ).with_actions

    search.present? ? result.do_search(search) : result
  end

  # lists running maintenance updates where this user is involved in
  def involved_patchinfos
    array = []

    ids = PackageIssue.open_issues_of_owner(id).with_patchinfo.distinct.select(:package_id)

    Package.where(id: ids).find_each do |p|
      hash = { package: { project: p.project.name, name: p.name } }
      issues = []

      p.issues.each do |is|
        i = {}
        i[:name] = is.name
        i[:tracker] = is.issue_tracker.name
        i[:label] = is.label
        i[:url] = is.url
        i[:summary] = is.summary
        i[:state] = is.state
        i[:login] = is.owner.login if is.owner
        i[:updated_at] = is.updated_at
        issues << i
      end

      hash[:issues] = issues
      array << hash
    end

    array
  end

  def user_relevant_packages_for_status
    MaintainedPackagesByUserFinder.new(self).call.pluck(:id)
  end

  def state
    return owner.state if owner

    self[:state]
  end

  def to_s
    login
  end

  def to_param
    to_s
  end

  # TODO: Remove once responsive_ux is out of beta
  def tasks
    Rails.cache.fetch("requests_for_#{cache_key_with_version}") do
      declined_requests.count +
        incoming_requests.count +
        involved_reviews.count
    end
  end

  def unread_notifications
    NotificationsFinder.new(notifications.for_web).unread.size
  end

  def watched_project_names
    Rails.cache.fetch(['watched_project_names', self]) do
      Project.where(id: watched_projects.select(:project_id)).order(:name).pluck(:name)
    end
  end

  def add_watched_project(name)
    watched_projects.create(project: Project.find_by_name!(name))
    clear_watched_projects_cache
  end

  def remove_watched_project(name)
    watched_projects.joins(:project).where(projects: { name: name }).delete_all
    clear_watched_projects_cache
  end

  # Needed to clear cache even when user's updated_at timestamp did not change,
  # aka. changes within the same second. Mainly an issue when in our test suite
  def clear_watched_projects_cache
    Rails.cache.delete(['watched_project_names', self])
  end

  def watches?(name)
    watched_project_names.include?(name)
  end

  def update_globalroles(global_roles)
    roles.replace(global_roles + roles.where(global: false))
  end

  def add_globalrole(global_role)
    update_globalroles(global_role + roles.global)
  end

  def display_name
    address = Mail::Address.new(email)
    address.display_name = realname
    address.format
  end

  def name
    realname.presence || login
  end

  def combined_rss_feed_items
    Notification.for_rss.where(subscriber: self).or(
      Notification.for_rss.where(subscriber: groups)
    ).order(created_at: :desc, id: :desc).limit(Notification::MAX_RSS_ITEMS_PER_USER)
  end

  def mark_login!
    update(last_logged_in_at: Time.zone.today, login_failure_count: 0)
  end

  def count_login_failure
    update(login_failure_count: login_failure_count + 1)
  end

  def proxy_realname(env)
    return unless env['HTTP_X_FIRSTNAME'].present? && env['HTTP_X_LASTNAME'].present?

    env['HTTP_X_FIRSTNAME'].force_encoding('UTF-8') + ' ' + env['HTTP_X_LASTNAME'].force_encoding('UTF-8')
  end

  def update_login_values(env)
    # updates user's email and real name using data transmitted by authentication proxy
    self.email = env['HTTP_X_EMAIL'] if env['HTTP_X_EMAIL'].present?
    self.realname = proxy_realname(env) if proxy_realname(env)

    self.last_logged_in_at = Time.zone.today
    self.login_failure_count = 0

    if changes.any?
      logger.info "updating email for user #{login} from proxy header: old:#{email}|new:#{env['HTTP_X_EMAIL']}" if changes.keys.include?('email')

      # At this point some login value changed, so a successful log in is tracked
      RabbitmqBus.send_to_bus('metrics', 'login,access_point=webui value=1')
    end

    save
  end

  def send_metric_for_beta_change
    channel = (in_beta? ? 'joined_beta' : 'left_beta')
    RabbitmqBus.send_to_bus('metrics', "user.#{channel} value=1")
  end

  def run_as
    before = User.session
    begin
      User.session = self
      yield
    ensure
      User.session = before
    end
  end

  private

  # The currently logged in user (might be nil). It's reset after
  # every request and normally set during authentification
  def self.current
    Thread.current[:user]
  end
  private_class_method :current

  def self.nobody
    Thread.current[:nobody] ||= find_nobody!
  end
  private_class_method :nobody

  def password_validation
    return if password_digest || deprecated_password

    errors.add(:password, 'can\'t be blank')
  end

  # FIXME: This should be a policy
  def can_modify_project_internal(project, ignore_lock)
    # The ordering is important because of the lock status check
    return false if !ignore_lock && project.is_locked?
    return true if is_admin?

    return true if has_global_permission?('change_project')
    return true if has_local_permission?('change_project', project)
    return true if project.name == home_project_name # users tend to remove themself, allow to re-add them

    false
  end

  # Hashes the given parameter by the selected hashing method. It uses the
  # "password_salt" property's value to make the hashing more secure.
  def hash_string(value)
    crypt2index = { 'md5crypt' => 1,
                    'sha256crypt' => 5 }
    if deprecated_password_hash_type == 'md5'
      Digest::MD5.hexdigest(value + deprecated_password_salt)
    elsif crypt2index.key?(deprecated_password_hash_type)
      value.crypt("$#{crypt2index[deprecated_password_hash_type]}$#{deprecated_password_salt}$").split('$')[3]
    end
  end

  cattr_accessor :lookup_strategy do
    @@lstrategy = if Configuration.ldapgroup_enabled?
                    UserLdapStrategy.new
                  else
                    UserBasicStrategy.new
                  end
  end
end

# == Schema Information
#
# Table name: users
#
#  id                            :integer          not null, primary key
#  adminnote                     :text(65535)
#  deprecated_password           :string(255)      indexed
#  deprecated_password_hash_type :string(255)
#  deprecated_password_salt      :string(255)
#  email                         :string(200)      default(""), not null
#  ignore_auth_services          :boolean          default(FALSE)
#  in_beta                       :boolean          default(FALSE)
#  in_rollout                    :boolean          default(TRUE)
#  last_logged_in_at             :datetime
#  login                         :text(65535)      indexed
#  login_failure_count           :integer          default(0), not null
#  password_digest               :string(255)
#  realname                      :string(200)      default(""), not null
#  state                         :string(11)       default("unconfirmed")
#  created_at                    :datetime
#  updated_at                    :datetime
#  owner_id                      :integer
#
# Indexes
#
#  users_login_index     (login) UNIQUE
#  users_password_index  (deprecated_password)
#
