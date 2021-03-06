# coding: utf-8
class Reward < ActiveRecord::Base
  include I18n::Alchemy
  include RankedModel
  include ERB::Util

  before_destroy :check_if_is_destroyable

  belongs_to :project
  has_many :payments, through: :contributions
  has_many :contributions, dependent: :nullify

  ranks :row_order, with_same: :project_id

  validates_presence_of :minimum_value, :description, :deliver_at #, :days_to_delivery
  validates_numericality_of :minimum_value, greater_than_or_equal_to: 0.00, message: 'Value must be greater than or equal to $ 10'
  validates_numericality_of :maximum_contributions, only_integer: true, greater_than: 0, allow_nil: true
  validate :deliver_at_cannot_be_in_the_past
  scope :remaining, -> { where("
                               rewards.maximum_contributions IS NULL
                               OR (
                                rewards.maximum_contributions IS NOT NULL
                                AND (
                                      SELECT
                                      COUNT(distinct c.id)
                                      FROM
                                        contributions c JOIN payments p ON p.contribution_id = c.id
                                      WHERE
                                        (p.state = 'paid' OR
                                        p.waiting_payment)
                                        AND reward_id = rewards.id
                                    ) < maximum_contributions)") }
  scope :sort_asc, -> { order('id ASC') }

  delegate :display_deliver_estimate, :display_remaining, :name, :display_minimum, :short_description,
           :medium_description, :last_description, :display_description, to: :decorator

  before_save :log_changes
  after_save :expires_project_cache

  def deliver_at_cannot_be_in_the_past
    self.errors.add(:deliver_at, "Estimated delivery must be greater than the date on which the project ends") if
      self.project.expires_at.present? ? self.deliver_at < self.project.expires_at.beginning_of_month : self.deliver_at < Time.current.beginning_of_month
  end

  def log_changes
    self.last_changes = self.changes.to_json
  end

  def to_s
    display_description
  end

  def decorator
    @decorator ||= RewardDecorator.new(self)
  end

  def sold_out?
    #maximum_contributions && total_compromised >= maximum_contributions
    pluck_from_database('sold_out')
  end

  def any_sold?
    total_compromised > 0
  end

  def total_contributions states = %w(paid pending)
    payments.with_states(states).count("DISTINCT contributions.id")
  end

  def total_compromised
    paid_count + in_time_to_confirm
  end

  def paid_count
    pluck_from_database('paid_count')
  end

  def in_time_to_confirm
    pluck_from_database('waiting_payment_count')
  end

  def remaining
    return nil unless maximum_contributions
    maximum_contributions - total_compromised
  end

  def check_if_is_destroyable
    if any_sold?
      project.errors.add 'reward.destroy', "can't destroy"
      return false
    end
  end

  def expires_project_cache
    project.expires_fragments 'project-rewards'
  end

  private
  def pluck_from_database attribute
    Reward.where(id: self.id).pluck("rewards.#{attribute}").first
  end
end
