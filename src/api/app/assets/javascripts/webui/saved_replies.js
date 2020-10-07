$(document).ready(function() {
  $('body').on('change', '.saved_replies_input', function() {
    var savedRepliesSelect = $(this);
    var savedReplyId = savedRepliesSelect.val();
    var commentableId = savedRepliesSelect.attr('data-comment-field-id');
    var dataId = '[data-comment-field-id="' + commentableId + '"]';
    var commentBody = $('textarea' + dataId);
    var spinner = $('.saved_replies .fa-spinner' + dataId);

    if (savedReplyId) {
      spinner.toggleClass('invisible');
      savedRepliesSelect.prop('disabled', 'disabled');
      commentBody.prop('disabled', 'disabled');

      $.getJSON('/my/saved_replies/' + savedReplyId, function(data) {
        if (data && data.body) {
          commentBody.val(data.body);
        }

        spinner.toggleClass('invisible');
        savedRepliesSelect.prop('disabled', false);
        commentBody.prop('disabled', false);
      });
    } else {
      commentBody.val('');
    }
  });
});
