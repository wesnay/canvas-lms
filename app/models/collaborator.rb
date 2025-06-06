# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Collaborator < ActiveRecord::Base
  belongs_to :collaboration
  belongs_to :group
  belongs_to :user

  has_a_broadcast_policy

  def course_broadcast_data
    group&.broadcast_data
  end

  set_broadcast_policy do |p|
    p.dispatch :collaboration_invitation
    p.to do
      users = group_id.nil? ? [user] : group.users - [user]
      if context.is_a?(Course)
        if context.workflow_state.in?(["available", "completed"])
          enrolled_user_ids = context.enrollments.active_by_date.where(user_id: users).pluck(:user_id).to_set
          users = users.select { |u| enrolled_user_ids.include?(u.id) }
        else
          users = [] # do not send notifications to any users if the course is unpublished
        end
      end
      if collaboration.collaboration_type == "google_docs"
        users.map(&:gmail_channel)
      else
        users
      end
    end
    p.whenever do |record|
      if record.group_id.nil?
        record.previously_new_record? && record.collaboration && record.user != record.collaboration.user
      else
        record.previously_new_record? && record.collaboration
      end
    end
    p.data { course_broadcast_data }
  end

  def context
    collaboration.try(:context)
  end
end
