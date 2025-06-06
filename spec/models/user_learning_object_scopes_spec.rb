# frozen_string_literal: true

#
# Copyright (C) 2018 - present Instructure, Inc.
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

describe UserLearningObjectScopes do
  describe "assignments_visible_in_course" do
    before do
      @teacher_enrollment = course_with_teacher(active_course: true)
      @course_section = @course.course_sections.create
      @student1 = User.create
      @student2 = User.create
      @student3 = User.create
      @assignment = Assignment.create!(title: "title", context: @course, only_visible_to_overrides: true)
      @unpublished_assignment = Assignment.create!(title: "title", context: @course, only_visible_to_overrides: false)
      @unpublished_assignment.unpublish
      @course.enroll_student(@student2, enrollment_state: "active")
      @section = @course.course_sections.create!(name: "test section")
      student_in_section(@section, user: @student1)
      create_section_override_for_assignment(@assignment, { course_section: @section })
      @course.reload
    end

    context "as student" do
      it "returns assignments only when a student has overrides" do
        expect(@student1.assignments_visible_in_course(@course)).to include @assignment
        expect(@student2.assignments_visible_in_course(@course)).not_to include @assignment
        expect(@student1.assignments_visible_in_course(@course)).not_to include @unpublished_assignment
      end
    end

    context "as teacher" do
      it "returns all assignments" do
        expect(@teacher_enrollment.user.assignments_visible_in_course(@course)).to include @assignment
        expect(@teacher_enrollment.user.assignments_visible_in_course(@course)).to include @unpublished_assignment
      end
    end

    context "as observer" do
      before do
        @observer = User.create
        @observer_enrollment = @course.enroll_user(@observer,
                                                   "ObserverEnrollment",
                                                   section: @section2,
                                                   enrollment_state: "active",
                                                   allow_multiple_enrollments: true)
      end

      context "observer watching student with visibility" do
        before { @observer_enrollment.update_attribute(:associated_user_id, @student1.id) }

        it "is true" do
          expect(@observer.assignments_visible_in_course(@course)).to include @assignment
        end
      end

      context "observer watching student without visibility" do
        before { @observer_enrollment.update_attribute(:associated_user_id, @student2.id) }

        it "is false" do
          expect(@observer.assignments_visible_in_course(@course)).not_to include @assignment
        end
      end

      context "observer watching a only section" do
        it "is true" do
          expect(@observer.assignments_visible_in_course(@course)).to include @assignment
        end
      end
    end
  end

  describe "assignments_for_student" do
    before :once do
      course_with_student(active_all: true)
      assignment_quiz([], course: @course, user: @user)
    end

    def create_assignment_with_override(opts = {})
      student = opts[:student] || @student
      @course.enrollments.where(user_id: student).destroy_all # student removed from default section
      section = @course.course_sections.create!
      student_in_section(section, user: student)
      @assignment.only_visible_to_overrides = true
      @assignment.publish
      @quiz.due_at = opts[:due_at] || 2.days.from_now
      @quiz.save!
      if opts[:override]
        create_section_override_for_assignment(@assignment, course_section: section)
      end
      @assignment
    end

    it "does not include unpublished assignments" do
      course_with_student(active_all: true)
      assignment_quiz([], course: @course, user: @user)
      @assignment.unpublish
      @quiz.unlock_at = 1.hour.ago
      @quiz.lock_at = nil
      @quiz.due_at = 2.days.from_now
      @quiz.save!
      assignment_quiz([], course: @course, user: @user)
      @quiz.unlock_at = 1.hour.ago
      @quiz.lock_at = nil
      @quiz.due_at = 2.days.from_now
      @quiz.save!
      SubmissionLifecycleManager.recompute(@quiz.assignment)

      expect(@student.assignments_for_student("submitting", contexts: [@course]).count).to eq 1
    end

    # NOTE: More thorough testing of the Assignment#not_locked named scope is in assignment_spec.rb
    context "locked assignments" do
      before do
        # Setup default values for tests (leave unsaved for easy changes)
        @quiz.unlock_at = nil
        @quiz.lock_at = nil
        @quiz.due_at = 2.days.from_now
      end

      it "includes assignments with no due date but have overrides that are due" do
        @quiz.due_at = nil
        @quiz.save!
        section = @course.course_sections.create! name: "Test"
        @student = student_in_section section
        override = @quiz.assignment.assignment_overrides.build
        override.title = "Shows up in todos"
        override.set_type = "CourseSection"
        override.set = section
        override.due_at = 1.week.from_now - 1.day
        override.due_at_overridden = true
        override.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        expect(@student.assignments_for_student("submitting", contexts: [@course]))
          .to include @quiz.assignment
      end

      it "includes assignments with no locks" do
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        list = @student.assignments_for_student("submitting", contexts: [@course])
        expect(list.size).to be 1
        expect(list.first.title).to eq "Test Assignment"
      end

      it "includes assignments with unlock_at in the past" do
        @quiz.unlock_at = 1.hour.ago
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        list = @student.assignments_for_student("submitting", contexts: [@course])
        expect(list.size).to be 1
        expect(list.first.title).to eq "Test Assignment"
      end

      it "includes assignments with lock_at in the future" do
        @quiz.lock_at = 3.days.from_now
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        list = @student.assignments_for_student("submitting", contexts: [@course])
        expect(list.size).to be 1
        expect(list.first.title).to eq "Test Assignment"
      end

      it "does not include assignments where unlock_at is in future" do
        @quiz.unlock_at = 1.hour.from_now
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        expect(@student.assignments_for_student("submitting", contexts: [@course]).count).to eq 0
      end

      it "does not include assignments where lock_at is in past" do
        @quiz.due_at = 2.hours.ago
        @quiz.lock_at = 1.hour.ago
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        expect(@student.assignments_for_student("submitting", contexts: [@course]).count).to eq 0
      end

      context "include_locked" do
        it "includes assignments where unlock_at is in future" do
          @quiz.unlock_at = 1.hour.from_now
          @quiz.save!
          SubmissionLifecycleManager.recompute(@quiz.assignment)
          list = @student.assignments_for_student("submitting", include_locked: true, contexts: [@course])
          expect(list.count).to eq 1
        end

        it "includes assignments where lock_at is in past" do
          @quiz.due_at = 2.hours.ago
          @quiz.lock_at = 1.hour.ago
          @quiz.save!
          SubmissionLifecycleManager.recompute(@quiz.assignment)
          list = @student.assignments_for_student("submitting", include_locked: true, contexts: [@course])
          expect(list.count).to eq 1
        end
      end
    end

    context "ungraded assignments" do
      before :once do
        @assignment = @course.assignments.create! title: "blah!", due_at: 1.day.from_now, submission_types: "not_graded"
        SubmissionLifecycleManager.recompute(@assignment)
      end

      it "excludes ungraded assignments by default" do
        expect(@student.assignments_for_student("submitting")).not_to include @assignment
      end

      it "includes future ungraded assignments if requested" do
        expect(@student.assignments_for_student("submitting", include_ungraded: true)).to include @assignment
      end
    end

    context "differentiated_assignments" do
      it "does not return the assignments without an override for the student" do
        assignment = create_assignment_with_override(due_at: 2.days.from_now)
        SubmissionLifecycleManager.recompute(assignment)
        expect(@student.assignments_for_student("submitting", contexts: Course.all)).not_to include(assignment)
      end

      it "returns the assignments with an override" do
        assignment = create_assignment_with_override(override: true, due_at: 2.days.from_now)
        SubmissionLifecycleManager.recompute(assignment)
        expect(@student.assignments_for_student("submitting", contexts: Course.all)).to include(assignment)
      end

      it "returns assignments with due dates in the 'due_after' 'due_before' window for the student" do
        # if this spec fails due to new logic, please consider updating ungraded quizzes due date logic
        # and verifying the differentiated assignments spec for ungraded quizzes in this file
        assignment = create_assignment_with_override(override: true, due_at: 2.days.from_now)
        ad_hoc = create_adhoc_override_for_assignment(assignment, @student)
        ad_hoc.due_at = 2.weeks.from_now
        ad_hoc.due_at_overridden = true
        ad_hoc.save!
        SubmissionLifecycleManager.recompute(assignment)
        assigns1 = @student.assignments_for_student("submitting", due_after: 1.week.from_now, due_before: 3.weeks.from_now)
        assigns2 = @student.assignments_for_student("submitting", due_after: Time.zone.now, due_before: 1.week.from_now)
        expect(assigns1).to include(assignment)
        expect(assigns2).not_to include(assignment)
      end

      it "returns assignments with overrides where the due date is not overridden for the student" do
        # if this spec fails due to new logic, please consider updating ungraded quizzes due date logic
        # and verifying the differentiated assignments spec for ungraded quizzes in this file
        assignment = create_assignment_with_override(override: true, due_at: 2.days.from_now)
        ad_hoc = create_adhoc_override_for_assignment(assignment, @student)
        ad_hoc.lock_at = 2.weeks.from_now
        ad_hoc.lock_at_overridden = true
        ad_hoc.save!
        SubmissionLifecycleManager.recompute(assignment)
        assigns1 = @student.assignments_for_student("submitting", due_after: 1.week.from_now, due_before: 3.weeks.from_now)
        assigns2 = @student.assignments_for_student("submitting", due_after: Time.zone.now, due_before: 1.week.from_now)
        expect(assigns1).not_to include(assignment)
        expect(assigns2).to include(assignment)
      end

      it "does not return assignments where the override removes the user's due date" do
        # if this spec fails due to new logic, please consider updating ungraded quizzes due date logic
        # and verifying the differentiated assignments spec for ungraded quizzes in this file
        assignment = create_assignment_with_override(override: true, due_at: 2.days.from_now)
        ad_hoc = create_adhoc_override_for_assignment(assignment, @student)
        ad_hoc.due_at = nil
        ad_hoc.due_at_overridden = true
        ad_hoc.save!
        SubmissionLifecycleManager.recompute(assignment)
        assignments = @student.assignments_for_student("submitting", due_after: 4.weeks.ago, due_before: 4.weeks.from_now)
        expect(assignments).not_to include(assignment)
      end
    end

    context "include_concluded" do
      before :once do
        @u = User.create!

        @c1 = course_with_student(active_all: true, user: @u).course
        @q1 = assignment_quiz([], course: @c1, user: @user)

        @e2 = course_with_student(active_all: true, user: @u)
        @c2 = @e2.course
        @q2 = assignment_quiz([], course: @c2, user: @user)
        @e2.conclude
        SubmissionLifecycleManager.recompute(@q1.assignment)
        SubmissionLifecycleManager.recompute(@q2.assignment)
      end

      it "does not include assignments from concluded enrollments by default" do
        expect(@u.assignments_for_student("submitting").count).to eq 1
      end

      it "includes assignments from concluded enrollments if requested" do
        assignments = @u.assignments_for_student("submitting", include_concluded: true)

        expect(assignments.count).to eq 2
        expect(assignments.map(&:id).sort).to eq [@q1.assignment.id, @q2.assignment.id].sort
      end

      it "does not include assignments from soft concluded courses" do
        course_with_student(active_all: true)
        @course.enrollment_term.update_attribute(:end_at, 1.day.from_now)
        assignment_quiz([], course: @course, user: @user)
        @quiz.unlock_at = nil
        @quiz.lock_at = nil
        @quiz.due_at = 3.days.from_now
        @quiz.save!
        SubmissionLifecycleManager.recompute(@quiz.assignment)
        Timecop.travel(2.days) do
          EnrollmentState.recalculate_expired_states # runs periodically in background
          expect(@student.assignments_for_student("submitting", contexts: [@course]).count).to eq 0
        end
      end
    end

    context "context_codes" do
      before :once do
        @opts = { scope_only: true }
        @course1 = course_with_student(active_all: true).course
        @course2 = course_with_student(active_all: true, user: @student).course
        @assignment1 = assignment_model(context: @course1, due_at: 1.day.from_now, submission_types: "online_upload")
        @assignment2 = assignment_model(context: @course2, due_at: 1.day.from_now, submission_types: "online_upload")
        SubmissionLifecycleManager.recompute(@assignment1)
        SubmissionLifecycleManager.recompute(@assignment2)
      end

      it "includes assignments from active courses by default" do
        expect(@student.assignments_for_student("submitting", **@opts).order(:id)).to eq [@assignment1, @assignment2]
      end

      it "only includes assignments from given course ids" do
        opts = @opts.merge({ course_ids: [@course1.id], group_ids: [] })
        expect(@student.assignments_for_student("submitting", **opts).order(:id)).to eq [@assignment1]
      end
    end

    context "sharding" do
      specs_require_sharding

      it "includes assignments from other shards" do
        student = @shard1.activate { user_factory }
        assignment = create_assignment_with_override(student:, override: true, due_at: 2.days.from_now)
        SubmissionLifecycleManager.recompute(assignment)
        expect(student.assignments_needing_submitting).to eq [assignment]
      end
    end

    it "always has the only_visible_to_overrides attribute" do
      course_with_student(active_all: true)
      assignment_quiz([], course: @course, user: @user)
      @quiz.unlock_at = nil
      @quiz.lock_at = nil
      @quiz.due_at = 2.days.from_now
      @quiz.save!
      SubmissionLifecycleManager.recompute(@quiz.assignment)
      assignments = @student.assignments_for_student("submitting", contexts: [@course])
      expect(assignments[0]).to have_attribute :only_visible_to_overrides
    end

    context "sub_assignments" do
      let(:root_account) { Account.default }

      before :once do
        @sub_account1 = root_account.sub_accounts.create!(name: "sub-account1")
        @sub_account2 = root_account.sub_accounts.create!(name: "sub-account2")
        root_account.allow_feature!(:discussion_checkpoints)
      end

      it "returns sub_assignments from root account with discussion checkpoints FF enabled" do
        root_account.enable_feature!(:discussion_checkpoints)
        course_with_student(active_all: true, account: root_account)
        reply_to_topic, reply_to_entry = graded_discussion_topic_with_checkpoints(context: @course)
        list = @student.assignments_for_student("submitting", is_sub_assignment: true, contexts: [@course])
        expect(list.size).to be 2
        expect(list.pluck(:id)).to match_array([reply_to_topic.id, reply_to_entry.id])
      end

      it "returns sub_assignments only from sub-accounts with discussion checkpoints FF enabled" do
        # sub_account1 has FF enabled
        @sub_account1.enable_feature!(:discussion_checkpoints)
        course_with_student(active_all: true, account: @sub_account1)
        @course1 = @course
        reply_to_topic, reply_to_entry = graded_discussion_topic_with_checkpoints(context: @course1)

        # temporary enable FF for sub_account2 to create discussion with checkpoints
        course_with_student(active_all: true, account: @sub_account2, user: @student)
        @sub_account2.enable_feature!(:discussion_checkpoints)
        graded_discussion_topic_with_checkpoints(context: @course)
        # sub_account2 has FF disabled
        @sub_account2.disable_feature!(:discussion_checkpoints)

        list = @student.assignments_for_student("submitting", is_sub_assignment: true, contexts: [@course1, @course])
        expect(list.size).to be 2
        expect(list.pluck(:id)).to match_array([reply_to_topic.id, reply_to_entry.id])
      end
    end
  end

  describe "assignments_needing_submitting" do
    before :once do
      course_with_student(active_all: true)
    end

    it "excludes assignments with due dates in the past" do
      past_assignment = @course.assignments.create! title: "blah!", due_at: 1.day.ago, submission_types: "not_graded"
      SubmissionLifecycleManager.recompute(past_assignment)
      expect(@student.assignments_needing_submitting).not_to include past_assignment
    end

    it "excludes assignments that aren't expecting a submission" do
      assignment = @course.assignments.create! title: "no submission", due_at: 1.day.from_now, submission_types: "none"
      SubmissionLifecycleManager.recompute(assignment)
      expect(@student.assignments_needing_submitting).not_to include assignment
    end

    it "excludes assignments that have an existing submission" do
      assignment = @course.assignments.create! title: "submitted", due_at: 1.day.from_now, submission_types: "online_url"
      submission_model(assignment:, user: @student, submission_type: "online_url", url: "www.hi.com")
      SubmissionLifecycleManager.recompute(assignment)
      expect(@student.assignments_needing_submitting).not_to include assignment
    end
  end

  describe "#submitted_assignments" do
    before :once do
      course_with_student(active_all: true)
    end

    it "excludes assignments that don't have a submission" do
      assignment = @course.assignments.create! title: "submitted", due_at: 1.day.from_now, submission_types: "online_url"
      SubmissionLifecycleManager.recompute(assignment)
      expect(@student.submitted_assignments).not_to include assignment
    end
  end

  describe "ungraded_quizzes" do
    before(:once) do
      course_with_student active_all: true
      @quiz = @course.quizzes.create!(title: "some quiz", quiz_type: "survey", due_at: 1.day.from_now)
      @quiz.publish!
    end

    it "includes ungraded quizzes" do
      expect(@student.ungraded_quizzes(needing_submitting: true)).to include @quiz
    end

    it "excludes graded quizzes" do
      other_quiz = @course.quizzes.create!(title: "some quiz", quiz_type: "assignment", due_at: 1.day.from_now)
      other_quiz.publish!
      expect(@student.ungraded_quizzes(needing_submitting: true)).not_to include other_quiz
    end

    it "excludes unpublished quizzes" do
      other_quiz = @course.quizzes.create!(title: "some quiz", quiz_type: "survey", due_at: 1.day.from_now)
      expect(@student.ungraded_quizzes(needing_submitting: true)).not_to include other_quiz
    end

    it "excludes locked quizzes" do
      @quiz.unlock_at = 1.day.from_now
      @quiz.save!
      expect(@student.ungraded_quizzes(needing_submitting: true)).not_to include @quiz
    end

    it "includes locked quizzes if requested" do
      @quiz.unlock_at = 1.day.from_now
      @quiz.save!
      expect(@student.ungraded_quizzes(include_locked: true, needing_submitting: true)).to include @quiz
    end

    it "excludes submitted quizzes unless requested" do
      qs = @quiz.quiz_submissions.build user: @student
      qs.workflow_state = "complete"
      qs.save!
      expect(@student.ungraded_quizzes(needing_submitting: true)).not_to include @quiz
      expect(@student.ungraded_quizzes(needing_submitting: false)).to include @quiz
    end

    it "filters by enrollment state" do
      @student.enrollments.where(course: @course).first.complete!
      expect(@student.ungraded_quizzes(needing_submitting: true)).not_to include @quiz
    end

    context "differentiated_assignments" do
      def create_ungraded_quiz_with_override(opts = {})
        student = opts[:student] || @student
        @course.enrollments.where(user_id: student).destroy_all # student removed from default section
        section = @course.course_sections.create!
        student_in_section(section, user: student)
        @quiz = @course.quizzes.create!(quiz_type: "practice_quiz", title: "practice quiz")
        @quiz.due_at = 1.day.from_now
        @quiz.only_visible_to_overrides = true
        @quiz.publish!
        if opts[:override]
          create_section_override_for_assignment(@quiz, { course_section: section })
        end
        @quiz
      end

      it "filters by due date" do
        expect(@student.ungraded_quizzes(due_after: 2.days.from_now, needing_submitting: true)).not_to include @quiz
      end

      it "returns ungraded quizzes with due dates in the 'due_after' 'due_before' window for the student" do
        quiz = create_ungraded_quiz_with_override(override: true)
        ad_hoc = create_adhoc_override_for_assignment(quiz, @student)
        ad_hoc.due_at = 2.weeks.from_now
        ad_hoc.due_at_overridden = true
        ad_hoc.save!
        quizzes1 = @student.ungraded_quizzes(due_after: 1.week.from_now, due_before: 3.weeks.from_now)
        quizzes2 = @student.ungraded_quizzes(due_after: Time.zone.now, due_before: 1.week.from_now)
        expect(quizzes1).to include(quiz)
        expect(quizzes2).not_to include(quiz)
      end

      it "returns ungraded quizzes with overrides where the due date is not overridden for the student" do
        quiz = create_ungraded_quiz_with_override(override: true)
        ad_hoc = create_adhoc_override_for_assignment(quiz, @student)
        ad_hoc.lock_at = 2.weeks.from_now
        ad_hoc.lock_at_overridden = true
        ad_hoc.save!
        quizzes1 = @student.ungraded_quizzes(due_after: 1.week.from_now, due_before: 3.weeks.from_now)
        quizzes2 = @student.ungraded_quizzes(due_after: Time.zone.now, due_before: 1.week.from_now)
        expect(quizzes1).not_to include(quiz)
        expect(quizzes2).to include(quiz)
      end

      it "does not return ungraded quizzes where an applicable due date is nil" do
        quiz = create_ungraded_quiz_with_override(override: true)
        ad_hoc = create_adhoc_override_for_assignment(quiz, @student)
        ad_hoc.due_at = nil
        ad_hoc.due_at_overridden = true
        ad_hoc.save!
        quizzes = @student.ungraded_quizzes(due_after: 4.weeks.ago, due_before: 4.weeks.from_now)
        expect(quizzes).not_to include(quiz)
      end
    end

    context "sharding" do
      specs_require_sharding
      it "includes quizzes from other shards" do
        other_user = @shard1.activate { user_factory }
        student_in_course course: @course, user: other_user, active_all: true
        expect(other_user.ungraded_quizzes(needing_submitting: true)).to include @quiz
      end
    end
  end

  describe "submissions_needing_peer_review" do
    before do
      @reviewer = course_with_student(active_all: true).user
      @reviewee = course_with_student(course: @course, active_all: true).user

      add_section("section1")
      @course.enroll_user(@reviewer,
                          "StudentEnrollment",
                          section: @course_section,
                          enrollment_state: "active",
                          allow_multiple_enrollments: true)
      @course.enroll_user(@reviewee,
                          "StudentEnrollment",
                          section: @course_section,
                          enrollment_state: "active",
                          allow_multiple_enrollments: true)

      assignment_model(course: @course, peer_reviews: true)

      @assessment_request = @assignment.assign_peer_review(@reviewer, @reviewee)
    end

    it "includeds assessment requests where the user is the assessor" do
      expect(@reviewer.submissions_needing_peer_review.length).to eq 1
    end

    it "does not include assessment requests that have been ignored" do
      Ignore.create!(asset: @assessment_request, user: @reviewer, purpose: "reviewing")
      expect(@reviewer.submissions_needing_peer_review.length).to eq 0
    end

    it "does not include assessment requests the user does not have permission to perform" do
      @assignment.peer_reviews = false
      @assignment.save!
      expect(@reviewer.submissions_needing_peer_review.length).to eq 0
    end

    it "does not include assessment requests for users not assigned the assignment" do
      @assignment.update(only_visible_to_overrides: true)
      # create a new section with only the reviewer student
      # since the reviewee is no longer assigned @assignment, the reviewer should
      # have nothing to do.
      add_section("section2")
      @course.enroll_user(@reviewer,
                          "StudentEnrollment",
                          section: @course_section,
                          enrollment_state: "active",
                          allow_multiple_enrollments: true)
      override = @assignment.assignment_overrides.build
      override.set = @course_section
      override.save!
      AssignmentOverrideApplicator.assignment_with_overrides(@assignment, [@override])

      expect(@reviewer.submissions_needing_peer_review.length).to eq 0
    end

    it "does not include assessment requests when the user of the assessment is not an active enrollment" do
      @assessment_request.user.enrollments.update_all(workflow_state: "inactive")
      expect(@reviewer.submissions_needing_peer_review.length).to eq 0
    end
  end

  context "assignments_needing_grading" do
    before :once do
      # create courses and sections
      @course1 = course_with_teacher(active_all: true).course
      @course2 = course_with_teacher(active_all: true, user: @teacher).course
      @section1b = @course1.course_sections.create!(name: "section B")
      @section2b = @course2.course_sections.create!(name: "section B")

      # put a student in each section
      @student_a = user_with_pseudonym(active_all: true, name: "StudentA", username: "studentA@instructure.com")
      @student_b = user_with_pseudonym(active_all: true, name: "StudentB", username: "studentB@instructure.com")
      @course1.enroll_student(@student_a).update_attribute(:workflow_state, "active")
      @section1b.enroll_user(@student_b, "StudentEnrollment", "active")
      @course2.enroll_student(@student_a).update_attribute(:workflow_state, "active")
      @section2b.enroll_user(@student_b, "StudentEnrollment", "active")

      # set up a TA, section-limited in one course and not the other
      @ta = user_with_pseudonym(active_all: true, name: "TA", username: "ta@instructure.com")
      @course1.enroll_user(@ta, "TaEnrollment", enrollment_state: "active", limit_privileges_to_course_section: true)
      @course2.enroll_user(@ta, "TaEnrollment", enrollment_state: "active", limit_privileges_to_course_section: false)

      # make some assignments and submissions
      [@course1, @course2].each do |course|
        assignment = course.assignments.create!(title: "some assignment", submission_types: ["online_text_entry"])
        [@student_a, @student_b].each do |student|
          assignment.submit_homework student, body: "submission for #{student.name}"
        end
      end
    end

    it "does not count assignments in soft concluded courses" do
      @course.enrollment_term.update_attribute(:end_at, 1.day.from_now)
      Timecop.travel(1.week) do
        EnrollmentState.recalculate_expired_states # runs periodically in background
        expect(@teacher.reload.assignments_needing_grading.size).to be 0
      end
    end

    it "does not duplicate assignments for teachers in multiple sections" do
      @course2.enroll_teacher(@teacher, enrollment_state: "active", section: @section2b, allow_multiple_enrollments: true)
      expect(@teacher.assignments_needing_grading.count).to eq 2
    end

    it "counts assignments with ungraded submissions across multiple courses" do
      expect(@teacher.assignments_needing_grading.size).to be(2)
      expect(@teacher.assignments_needing_grading).to include(@course1.assignments.first)
      expect(@teacher.assignments_needing_grading).to include(@course2.assignments.first)

      # grade one submission for one assignment; these numbers don't change
      @course1.assignments.first.grade_student(@student_a, grade: "1", grader: @teacher)
      expect(@teacher.assignments_needing_grading.size).to be 2
      expect(@teacher.assignments_needing_grading).to include(@course1.assignments.first)
      expect(@teacher.assignments_needing_grading).to include(@course2.assignments.first)

      # grade the other submission; now course1's assignment no longer needs grading
      @course1.assignments.first.grade_student(@student_b, grade: "1", grader: @teacher)
      @teacher = User.find(@teacher.id)
      expect(@teacher.assignments_needing_grading.size).to be 1
      expect(@teacher.assignments_needing_grading).to include(@course2.assignments.first)
    end

    it "includes re-submitted submissions in the list of submissions needing grading" do
      @course1.assignments.first.grade_student(@student_a, grade: "1", grader: @teacher)
      @course1.assignments.first.grade_student(@student_b, grade: "1", grader: @teacher)
      expect(@teacher.assignments_needing_grading.size).to eq 1
      @course1.assignments.first.submit_homework(@student_a, body: "Changed my mind!")
      expect(@teacher.assignments_needing_grading.size).to eq 2
      expect(@teacher.assignments_needing_grading).to include @course1.assignments.first
    end

    it "only counts submissions in accessible course sections" do
      expect(@ta.assignments_needing_grading.size).to be 2
      expect(@ta.assignments_needing_grading).to include(@course1.assignments.first)
      expect(@ta.assignments_needing_grading).to include(@course2.assignments.first)

      # grade student A's submissions in both courses; now course1's assignment
      # should not show up because the TA doesn't have access to studentB's submission
      @course1.assignments.first.grade_student(@student_a, grade: "1", grader: @teacher)
      @course2.assignments.first.grade_student(@student_a, grade: "1", grader: @teacher)
      @ta = User.find(@ta.id)
      expect(@ta.assignments_needing_grading.size).to be 1
      expect(@ta.assignments_needing_grading(scope_only: true).to_a.size).to be 1
      expect(@ta.assignments_needing_grading).to include(@course2.assignments.first)

      # but if we enroll the TA in both sections of course1, it should be accessible
      @course1.enroll_user(@ta,
                           "TaEnrollment",
                           enrollment_state: "active",
                           section: @section1b,
                           allow_multiple_enrollments: true,
                           limit_privileges_to_course_section: true)
      @ta = User.find(@ta.id)
      expect(@ta.assignments_needing_grading.size).to be 2
      expect(@ta.assignments_needing_grading(scope_only: true).to_a.size).to be 2
      expect(@ta.assignments_needing_grading).to include(@course1.assignments.first)
      expect(@ta.assignments_needing_grading).to include(@course2.assignments.first)
    end

    it "does not count submissions for users with a deleted enrollment in the graders's section" do
      @course1.enroll_student(@student_b, allow_multiple_enrollments: true).update(workflow_state: "deleted")
      assignment = @course1.assignments.first
      assignment.grade_student(@student_a, grade: "1", grader: @teacher)
      expect(@ta.assignments_needing_grading(scope_only: true)).not_to include assignment
    end

    it "does not count submissions for sections where the grader has a deleted enrollment" do
      @course1.enroll_user(@ta, "TaEnrollment", allow_multiple_enrollments: true, section: @section1b).update(workflow_state: "deleted")
      assignment = @course1.assignments.first
      assignment.grade_student(@student_a, grade: "1", grader: @teacher)
      expect(@ta.assignments_needing_grading(scope_only: true)).not_to include assignment
    end

    it "does not count submissions for inactive students when they have active enrollments in other courses" do
      @course1.enroll_student(@student_b).update_attribute(:workflow_state, "inactive")
      assignment = @course1.assignments.first
      assignment.grade_student(@student_a, grade: "1", grader: @teacher)
      expect(@teacher.assignments_needing_grading(scope_only: true)).not_to include assignment
    end

    it "limits the number of returned assignments" do
      assignment_ids = create_records(Assignment, Array.new(20) do |x|
        {
          title: "excess assignment #{x}",
          submission_types: "online_text_entry",
          workflow_state: "available",
          context_type: "Course",
          context_id: @course1.id,
          root_account_id: @course1.root_account_id,
        }
      end)
      create_records(Submission, assignment_ids.map do |id|
        {
          assignment_id: id,
          course_id: @course1.id,
          user_id: @student_b.id,
          body: "hello",
          workflow_state: "submitted",
          submission_type: "online_text_entry"

        }
      end)
      expect(@teacher.assignments_needing_grading.size).to eq 15
    end

    it "always has the only_visible_to_overrides attribute" do
      expect(@teacher.assignments_needing_grading).to all(have_attribute(:only_visible_to_overrides))
    end

    context "is_sub_assignment" do
      before do
        @course1.account.enable_feature!(:discussion_checkpoints)
        @reply_to_topic, @reply_to_entry = graded_discussion_topic_with_checkpoints(context: @course1)
        @reply_to_topic.submit_homework @student_a, body: "checkpoint submission for #{@student_a.name}"
      end

      it "default false and does not return checkpointed sub-assignments" do
        expect(@teacher.assignments_needing_grading).not_to include(@reply_to_topic)
      end

      it "returns only checkpointed sub-assignments when true" do
        expect(@teacher.assignments_needing_grading(is_sub_assignment: true)).to eq([@reply_to_topic])
      end

      it "returns only checkpointed sub-assignments from the given course" do
        @course2.account.enable_feature!(:discussion_checkpoints)
        reply_to_topic2, _reply_to_entry2 = graded_discussion_topic_with_checkpoints(context: @course2)
        reply_to_topic2.submit_homework @student_a, body: "checkpoint submission for #{@student_a.name}"

        expect(@teacher.assignments_needing_grading(is_sub_assignment: true, course_ids: [@course1.id])).to eq([@reply_to_topic])
      end

      it "returns only active checkpointed sub-assignments" do
        reply_to_topic2, _reply_to_entry2 = graded_discussion_topic_with_checkpoints(context: @course1)
        reply_to_topic2.submit_homework @student_a, body: "checkpoint submission for #{@student_a.name}"

        expect(@teacher.assignments_needing_grading(is_sub_assignment: true)).to eq([@reply_to_topic, reply_to_topic2])

        reply_to_topic2.parent_assignment.workflow_state = "deleted"
        reply_to_topic2.parent_assignment.save!

        expect(@teacher.assignments_needing_grading(is_sub_assignment: true)).to eq([@reply_to_topic])
      end

      it "when false does not return parent assignments of sub-assignments" do
        @reply_to_entry.submit_homework @student_a, body: "checkpoint submission for #{@student_a.name}"
        expect(@teacher.assignments_needing_grading).not_to include(@reply_to_topic.parent_assignment)
      end
    end

    context "sharding" do
      specs_require_sharding

      before :once do
        @shard1.activate do
          @account = Account.create!
          @course3 = @account.courses.create!
          @course3.offer!
          @course3.enroll_teacher(@teacher).accept!
          @course3.enroll_student(@student_a).accept!
          @course3.enroll_student(@student_b).accept!
          @assignment3 = @course3.assignments.create!(title: "some assignment", submission_types: ["online_text_entry"])
          @assignment3.submit_homework @student_a, body: "submission for A"
        end
      end

      it "finds assignments from all shards" do
        [Shard.default, @shard1, @shard2].each do |shard|
          shard.activate do
            expect(@teacher.assignments_needing_grading.sort_by(&:id)).to eq(
              [@course1.assignments.first, @course2.assignments.first, @assignment3].sort_by(&:id)
            )
          end
        end
      end

      it "honors ignores for a separate shard" do
        @teacher.ignore_item!(@assignment3, "grading")
        expect(@teacher.assignments_needing_grading.sort_by(&:id)).to eq(
          [@course1.assignments.first, @course2.assignments.first].sort_by(&:id)
        )

        @shard1.activate do
          @assignment3.submit_homework @student_b, submission_type: "online_text_entry", body: "submission for B"
        end
        @teacher = User.find(@teacher.id)
        expect(@teacher.assignments_needing_grading.size).to eq 3
      end

      it "applies a global limit" do
        expect(@teacher.assignments_needing_grading(limit: 1).length).to eq 1
      end

      it "does not fail with the dynamic setting turned off" do
        [Shard.default, @shard1, @shard2].each do |shard|
          shard.activate do
            override_dynamic_settings(private: { canvas: { disable_needs_grading_queries: true } }) do
              expect(@teacher.assignments_needing_grading).to eq []
            end
          end
        end
      end
    end

    context "differentiated assignments" do
      before :once do
        @a2 = @course1.assignments.create!(title: "some assignment 2", submission_types: ["online_text_entry"])
        [@student_a, @student_b].each do |student|
          @a2.submit_homework student, body: "submission for #{student.name}"
        end

        @section1a = @course1.course_sections.create!(name: "Section One")
        student_in_section(@section1a, user: @student_b)

        assignments = @course1.assignments
        differentiated_assignment(assignment: assignments[0], course_section: @section1b)
        differentiated_assignment(assignment: assignments[1], course_section: @section1a)
      end

      it "does not include submissions from students without visibility" do
        expect(@teacher.assignments_needing_grading.length).to eq 2
      end
    end
  end

  describe "#submissions_needing_grading_count" do
    before :once do
      course_with_teacher(active_all: true)
      @sectionb = @course.course_sections.create!(name: "section B")
      @student_a = user_with_pseudonym(active_all: true, name: "StudentA", username: "studentA@instructure.com")
      @student_b = user_with_pseudonym(active_all: true, name: "StudentB", username: "studentB@instructure.com")
      @course.enroll_student(@student_a).update(workflow_state: "active")
      @sectionb.enroll_user(@student_b, "StudentEnrollment", "active")
    end

    it "shows counts for all submissions a grader can see" do
      assignment_model(course: @course, submission_types: ["online_text_entry"])
      [@student_a, @student_b].each do |student|
        @assignment.submit_homework student, body: "submission for #{student.name}"
      end

      expect(@teacher.submissions_needing_grading_count).to eq 2
    end

    it "does not show counts for submissions that a grader can't see due to enrollment visibility" do
      @enrollment.update(limit_privileges_to_course_section: true) # limit the teacher to only see one of the students
      assignment_model(course: @course, submission_types: ["online_text_entry"])
      [@student_a, @student_b].each do |student|
        @assignment.submit_homework student, body: "submission for #{student.name}"
      end

      expect(@teacher.submissions_needing_grading_count).to eq 1
    end

    it "does not show counts for submissions in a section where the grader is enrolled but is not a grader" do
      @enrollment.update(limit_privileges_to_course_section: true)
      @sectionb.enroll_user(@teacher, "StudentEnrollment", "active")
      assignment_model(course: @course, submission_types: ["online_text_entry"])
      [@student_a, @student_b].each do |student|
        @assignment.submit_homework student, body: "submission for #{student.name}"
      end

      expect(@teacher.submissions_needing_grading_count).to eq 1
    end
  end

  describe "#assignments_needing_moderation" do
    before :once do
      # create courses and sections
      @course1 = course_with_teacher(active_all: true).course
      @course2 = course_with_teacher(active_all: true, user: @teacher).course
      @section1b = @course1.course_sections.create!(name: "section B")
      @section2b = @course2.course_sections.create!(name: "section B")

      # put a student in each section
      @student_a = user_with_pseudonym(active_all: true, name: "StudentA", username: "studentA@instructure.com")
      @student_b = user_with_pseudonym(active_all: true, name: "StudentB", username: "studentB@instructure.com")
      @course1.enroll_student(@student_a).update_attribute(:workflow_state, "active")
      @section1b.enroll_user(@student_b, "StudentEnrollment", "active")
      @course2.enroll_student(@student_a).update_attribute(:workflow_state, "active")
      @section2b.enroll_user(@student_b, "StudentEnrollment", "active")

      # make some assignments and submissions
      [@course1, @course2].each do |course|
        assignment = course.assignments.create!(
          final_grader: @teacher,
          grader_count: 2,
          moderated_grading: true,
          submission_types: ["online_text_entry"],
          title: "some assignment"
        )
        [@student_a, @student_b].each do |student|
          assignment.submit_homework student, body: "submission for #{student.name}"
        end
      end
      @course2.assignments.first.update_attribute(:moderated_grading, true)
      @course2.assignments.first.update_attribute(:grader_count, 2)
    end

    it "does not count assignments with no provisional grades" do
      expect(@teacher.assignments_needing_moderation.length).to eq 0
    end

    it "shows a count for final grader" do
      assmt = @course2.assignments.first
      assmt.update!(final_grader: @teacher)
      assmt.grade_student(@student_a, grade: "1", grader: @teacher, provisional: true)
      expect(@teacher.assignments_needing_moderation).to eq [assmt]
    end

    it "does not show a count for admins that can moderate grades but are not final grader" do
      admin = account_admin_user(account: @course2.account)
      assmt = @course2.assignments.first
      assmt.update!(final_grader: @teacher)
      assmt.grade_student(@student_a, grade: "1", grader: @teacher, provisional: true)
      expect(admin.assignments_needing_moderation).to be_empty
    end

    it "does not count assignments whose grades have been published" do
      assmt = @course2.assignments.first
      assmt.update!(final_grader: @teacher)
      assmt.grade_student(@student_a, grade: "1", grader: @teacher, provisional: true)
      assmt.update!(grades_published_at: Time.now.utc)
      expect(@teacher.assignments_needing_moderation).to be_empty
    end

    it "does not return duplicates" do
      assmt = @course2.assignments.first
      assmt.update!(final_grader: @teacher)
      assmt.grade_student(@student_a, grade: "1", grader: @teacher, provisional: true)
      assmt.grade_student(@student_b, grade: "2", grader: @teacher, provisional: true)
      expect(@teacher.assignments_needing_moderation.length).to eq 1
      expect(@teacher.assignments_needing_moderation.first).to eq assmt
    end

    it "does not give a count for non-moderators" do
      assmt = @course2.assignments.first
      assmt.grade_student(@student_a, grade: "1", grader: @teacher, provisional: true)
      ta = ta_in_course(course: @course, active_all: true).user
      expect(ta.assignments_needing_moderation.length).to eq 0
    end
  end

  describe "discussion_topics_needing_viewing" do
    let(:opts) { { due_after: 1.day.ago, due_before: 2.days.from_now } }

    context "course discussions" do
      before do
        course_with_student(active_all: true)
        discussion_topic_model(context: @course)
        group_discussion_topic_model(context: @course)
        announcement_model(context: @course)
        @topic.publish!
        @group_topic.publish!
        @a.publish!
      end

      it "shows for ungraded discussion topics with todo dates within the opts date range" do
        @topic.todo_date = 1.day.from_now
        @topic.save!
        @group_topic.todo_date = 1.day.from_now
        @group_topic.save!
        expect(@student.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq [@topic, @group_topic, @a]
      end

      it "does not show for ungraded discussion topics with todo dates outside the range" do
        @topic.todo_date = 3.days.ago
        @topic.save!
        @group_topic.todo_date = 3.days.ago
        @group_topic.save!
        @a.posted_at = 3.days.ago
        @a.save!
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
      end

      it "does not show for ungraded discussion topics without todo dates" do
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq [@a]
      end

      it "does not show unpublished discussion topics" do
        teacher_in_course(course: @course)
        @topic.workflow_state = "unpublished"
        @topic.todo_date = 1.day.from_now
        @topic.save!
        @group_topic.workflow_state = "unpublished"
        @group_topic.todo_date = 1.day.from_now
        @group_topic.save!
        @a.delayed_post_at = 1.day.from_now
        @a.workflow_state = "post_delayed"
        @a.save!
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
        expect(@teacher.discussion_topics_needing_viewing(**opts)).to eq []
      end

      it "does not show for users not enrolled in course" do
        @topic.todo_date = 1.day.from_now
        @topic.save!
        @group_topic.todo_date = 1.day.from_now
        @group_topic.save!
        user1 = @student
        course_with_student(active_all: true)
        expect(user1.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq [@topic, @group_topic, @a]
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
      end

      it "does not show discussions that are graded" do
        a = @course.assignments.create!(title: "some assignment", points_possible: 5, due_at: 1.day.from_now)
        t = @course.discussion_topics.build(assignment: a, title: "some topic", message: "a little bit of content")
        t.save
        expect(t.assignment_id).to eql(a.id)
        expect(t.assignment).to eql(a)
        expect(@student.discussion_topics_needing_viewing(**opts)).not_to include t
      end

      context "locked discussion topics" do
        it "shows for ungraded discussion topics with unlock dates and todo dates within the opts date range" do
          @topic.delayed_post_at = 1.day.from_now
          @topic.todo_date = 1.day.from_now
          @topic.save!
          @group_topic.delayed_post_at = 1.day.from_now
          @group_topic.todo_date = 1.day.from_now
          @group_topic.save!
          expect(@student.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq [@topic, @group_topic, @a]
        end

        it "shows for ungraded discussion topics with lock dates and todo dates within the opts date range" do
          @topic.lock_at = 1.day.ago
          @topic.todo_date = 1.day.from_now
          @topic.save!
          @group_topic.lock_at = 1.day.ago
          @group_topic.todo_date = 1.day.from_now
          @group_topic.save!
          expect(@student.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq [@topic, @group_topic, @a]
        end

        it "does not show for locked announcements" do
          @a.lock_at = 1.day.ago
          @a.save!
          a2 = announcement_model(context: @course)
          a2.lock_at = nil
          a2.save!
          a3 = announcement_model(context: @course)
          a3.lock_at = 1.day.from_now
          a3.save!
          expect(@student.discussion_topics_needing_viewing(**opts)).to eq [a2, a3]
        end
      end

      context "include_concluded" do
        before :once do
          @u = User.create!

          @c1 = course_with_student(active_all: true, user: @u).course
          @dt1 = discussion_topic_model(context: @c1)
          @dt1.todo_date = Time.zone.now
          @dt1.save!
          @dt1.publish!

          @e2 = course_with_student(active_all: true, user: @u)
          @c2 = @e2.course
          @dt2 = discussion_topic_model(context: @c2)
          @dt2.todo_date = Time.zone.now
          @dt2.save!
          @dt2.publish!
          @e2.conclude
        end

        it "does not include topics from concluded enrollments by default" do
          expect(@u.discussion_topics_needing_viewing(**opts).count).to eq 1
        end

        it "includes topics from concluded enrollments if requested" do
          expect(@u.discussion_topics_needing_viewing(**opts, include_concluded: true).count).to eq 2
          expect(@u.discussion_topics_needing_viewing(**opts, include_concluded: true).map(&:id).sort).to eq [@dt1.id, @dt2.id].sort
        end
      end

      context "context_codes" do
        before :once do
          @opts = opts.merge({ scope_only: true })
          @course1 = course_with_student(active_all: true).course
          @course2 = course_with_student(active_all: true, user: @student).course
          group_with_user(active_all: true, user: @student)
          @discussion1 = discussion_topic_model(context: @course1, todo_date: 1.day.from_now)
          @discussion2 = discussion_topic_model(context: @course2, todo_date: 1.day.from_now)
          @group_discussion = discussion_topic_model(context: @group, todo_date: 1.day.from_now)
        end

        it "includes assignments from active courses by default" do
          expect(@student.discussion_topics_needing_viewing(**@opts).order(:id)).to eq [@discussion1, @discussion2, @group_discussion]
        end

        it "only includes assignments from given course/group ids" do
          expect(@student.discussion_topics_needing_viewing(**@opts, course_ids: [], group_ids: []).order(:id)).to eq []
          opts = @opts.merge({ course_ids: [@course1.id], group_ids: [@group.id] })
          expect(@student.discussion_topics_needing_viewing(**opts).order(:id)).to eq [@discussion1, @group_discussion]
        end
      end
    end

    context "discussions made within groups" do
      before do
        course_with_student(active_all: true)
        @group_category = @course.group_categories.create(name: "Project Group")
        @group1 = group_model(name: "Project Group 1", group_category: @group_category, context: @course)
        group_membership_model(group: @group1, user: @student)
        @course_topic = discussion_topic_model(context: @group1)
        @course_announcement = announcement_model(context: @group1)
        @account = @course.account
        @group_category = @account.group_categories.create(name: "Project Group")
        @group2 = group_model(name: "Project Group 2", group_category: @group_category, context: @account)
        group_membership_model(group: @group2, user: @student)
        @account_topic = discussion_topic_model(context: @group2)
        @account_announcement = announcement_model(context: @group2)
      end

      it "shows discussions with dates in the range" do
        @course_topic.todo_date = 1.day.from_now
        @course_topic.save!
        @account_topic.todo_date = 1.day.from_now
        @account_topic.save!
        topics = [@course_topic, @course_announcement, @account_topic, @account_announcement]
        expect(@student.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq topics
      end

      it "does not show for ungraded discussion topics with todo dates outside the range" do
        @course_topic.todo_date = 3.days.ago
        @course_topic.save!
        @course_announcement.posted_at = 3.days.ago
        @course_announcement.save!
        @account_topic.todo_date = 3.days.ago
        @account_topic.save!
        @account_announcement.posted_at = 3.days.ago
        @account_announcement.save!
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
      end

      it "does not show for ungraded discussion topics without todo dates" do
        topics = [@course_announcement, @account_announcement]
        expect(@student.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq topics
      end

      it "does not show unpublished discussion topics" do
        teacher_in_course(course: @course)
        group_membership_model(group: @group1, user: @teacher)
        group_membership_model(group: @group2, user: @teacher)
        @course_topic.workflow_state = "unpublished"
        @course_topic.todo_date = 1.day.from_now
        @account_topic.workflow_state = "unpublished"
        @account_topic.todo_date = 1.day.from_now
        @course_announcement.delayed_post_at = 1.day.from_now
        @course_announcement.workflow_state = "post_delayed"
        @account_announcement.delayed_post_at = 1.day.from_now
        @account_announcement.workflow_state = "post_delayed"
        topics = [@course_topic, @account_topic, @course_announcement, @account_announcement]
        topics.each(&:save!)
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
        expect(@teacher.discussion_topics_needing_viewing(**opts)).to eq []
      end

      it "does not show for users not in group" do
        @course_topic.todo_date = 1.day.from_now
        @course_topic.save!
        @account_topic.todo_date = 1.day.from_now
        @account_topic.save!
        user1 = @student
        course_with_student(active_all: true)
        topics = [@course_topic, @course_announcement, @account_topic, @account_announcement]
        expect(user1.discussion_topics_needing_viewing(**opts).sort_by(&:id)).to eq topics
        expect(@student.discussion_topics_needing_viewing(**opts)).to eq []
      end
    end
  end

  describe "wiki_pages_needing_viewing" do
    before do
      course_with_student(active_all: true)
      @course_page = wiki_page_model(course: @course)
      @group_category = @course.group_categories.create(name: "Project Group")
      @group1 = group_model(name: "Project Group 1", group_category: @group_category, context: @course)
      group_membership_model(group: @group1, user: @student)
      @group_page = wiki_page_model(course: @group1)
      account = @course.account
      @group_category = account.group_categories.create(name: "Project Group")
      @group2 = group_model(name: "Project Group 1", group_category: @group_category, context: account)
      group_membership_model(group: @group2, user: @student)
      @account_page = wiki_page_model(course: @group2)
    end

    let(:opts) { { due_after: 1.day.ago, due_before: 2.days.from_now } }

    it "shows for wiki pages with todo dates within the opts date range" do
      @course_page.todo_date = 1.day.from_now
      @group_page.todo_date = 1.day.from_now
      @account_page.todo_date = 1.day.from_now
      pages = [@course_page, @group_page, @account_page]
      pages.each(&:save!)
      expect(@student.wiki_pages_needing_viewing(**opts).sort_by(&:id)).to eq pages
    end

    it "does not show for wiki pages with todo dates outside the range" do
      @course_page.todo_date = 3.days.ago
      @group_page.todo_date = 3.days.ago
      @account_page.todo_date = 3.days.ago
      pages = [@course_page, @group_page, @account_page]
      pages.each(&:save!)
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
    end

    it "does not show for wiki pages without todo dates" do
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
    end

    it "does not show unpublished pages" do
      teacher_in_course(course: @course)
      @course_page.workflow_state = "unpublished"
      @course_page.todo_date = 1.day.from_now
      @course_page.save!
      @group_page.workflow_state = "unpublished"
      @group_page.todo_date = 1.day.from_now
      @account_page.workflow_state = "unpublished"
      @account_page.todo_date = 1.day.from_now
      pages = [@course_page, @group_page, @account_page]
      pages.each(&:save!)
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
      expect(@teacher.wiki_pages_needing_viewing(**opts)).to eq []
    end

    it "does not show for users not enrolled in course" do
      @course_page.todo_date = 1.day.from_now
      @group_page.todo_date = 1.day.from_now
      @account_page.todo_date = 1.day.from_now
      pages = [@course_page, @group_page, @account_page]
      pages.each(&:save!)
      user1 = @student
      course_with_student(active_all: true)
      expect(user1.wiki_pages_needing_viewing(**opts).sort_by(&:id)).to eq pages
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
    end

    it "does not show wiki pages that are not released to the user" do
      @course.conditional_release = true
      @course_page.todo_date = 1.day.from_now
      @course_page.save!
      add_section("Section 2")
      student2 = student_in_section(@course_section)
      wiki_page_assignment_model(wiki_page: @course_page)
      differentiated_assignment(assignment: @assignment, course_section: @course_section)
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
      expect(student2.wiki_pages_needing_viewing(**opts)).to eq [@course_page]
    end

    it "does not show wiki pages that are not visible to the user" do
      @course_page.update!(todo_date: 1.day.from_now, only_visible_to_overrides: true)
      section2 = add_section("Section 2")
      student2 = student_in_section(section2)
      @course_page.assignment_overrides.create!(set: section2)
      expect(@student.wiki_pages_needing_viewing(**opts)).to eq []
      expect(student2.wiki_pages_needing_viewing(**opts)).to eq [@course_page]
    end

    context "include_concluded" do
      before :once do
        @u = User.create!

        @c1 = course_with_student(active_all: true, user: @u).course
        @wp1 = wiki_page_model(course: @c1)
        @wp1.todo_date = Time.zone.now
        @wp1.save!

        @e2 = course_with_student(active_all: true, user: @u)
        @c2 = @e2.course
        @wp2 = wiki_page_model(course: @c2)
        @wp2.todo_date = Time.zone.now
        @wp2.save!
        @e2.conclude
      end

      it "does not include pages from concluded enrollments by default" do
        expect(@u.wiki_pages_needing_viewing(**opts).count).to eq 1
      end

      it "includes pages from concluded enrollments if requested" do
        expect(@u.wiki_pages_needing_viewing(**opts, include_concluded: true).count).to eq 2
        expect(@u.wiki_pages_needing_viewing(**opts, include_concluded: true).map(&:id).sort).to eq [@wp1.id, @wp2.id].sort
      end
    end

    context "context_codes" do
      before :once do
        @opts = opts.merge({ scope_only: true })
        @course1 = course_with_student(active_all: true).course
        @course2 = course_with_student(active_all: true, user: @student).course
        group_with_user(active_all: true, user: @student)
        @discussion1 = wiki_page_model(course: @course1, todo_date: 1.day.from_now)
        @discussion2 = wiki_page_model(course: @course2, todo_date: 1.day.from_now)
        @group_discussion = wiki_page_model(course: @group, todo_date: 1.day.from_now)
      end

      it "includes assignments from active courses by default" do
        expect(@student.wiki_pages_needing_viewing(**@opts).order(:id)).to eq [@discussion1, @discussion2, @group_discussion]
      end

      it "only includes assignments from given course/group ids" do
        expect(@student.wiki_pages_needing_viewing(**@opts, course_ids: [], group_ids: []).order(:id)).to eq []
        opts = @opts.merge({ course_ids: [@course1.id], group_ids: [@group.id] })
        expect(@student.wiki_pages_needing_viewing(**opts).order(:id)).to eq [@discussion1, @group_discussion]
      end
    end
  end
end
