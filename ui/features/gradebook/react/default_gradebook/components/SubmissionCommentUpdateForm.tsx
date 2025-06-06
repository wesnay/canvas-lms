/*
 * Copyright (C) 2017 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import {func, string} from 'prop-types'
import {useScope as createI18nScope} from '@canvas/i18n'
import SubmissionCommentForm from './SubmissionCommentForm'
import {Editor} from 'tinymce'

const I18n = createI18nScope('gradebook')

export default class SubmissionCommentUpdateForm extends SubmissionCommentForm {
  static propTypes = {
    // @ts-expect-error
    ...SubmissionCommentForm.propTypes,
    id: string.isRequired,
    updateSubmissionComment: func.isRequired,
  }

  initRCE(tinyeditor: Editor) {
    this.tinyeditor = tinyeditor
    this.rceRef.current?.focus()
  }

  componentDidMount(): void {
    if (!this.isRceLiteEnabled()) this.focusTextarea()
  }

  commentHasChanged() {
    const comment = this.state.comment.trim()
    return comment !== this.props.comment?.trim()
  }

  commentIsValid() {
    return super.commentIsValid() && this.commentHasChanged()
  }

  buttonLabels() {
    return {
      cancelButtonLabel: I18n.t('Cancel Updating Comment'),
      submitButtonLabel: I18n.t('Update Comment'),
    }
  }

  publishComment() {
    // @ts-expect-error
    return this.props.updateSubmissionComment(this.state.comment, this.props.id)
  }

  showButtons() {
    return true
  }
}
