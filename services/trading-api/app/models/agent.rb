class Agent < ApplicationRecord
  # Associations
  has_one :wallet, dependent: :destroy
  has_many :trades, dependent: :restrict_with_error
  has_many :positions, dependent: :destroy
  has_many :watchlists, dependent: :destroy

  # Validations
  validates :agent_id, presence: true, uniqueness: true
  validates :name, presence: true
  validates :role, presence: true, inclusion: { in: %w[trader infrastructure analyst] }
  validates :status, presence: true, inclusion: { in: %w[active paused disabled] }
  validates :default_execution_policy, presence: true, inclusion: { in: %w[immediate allow_extended queue_until_open] }

  # Scopes
  scope :active, -> { where(status: 'active') }
  scope :traders, -> { where(role: 'trader') }
  scope :infrastructure, -> { where(role: 'infrastructure') }
  scope :analysts, -> { where(role: 'analyst') }

  # Instance methods
  def trader?
    role == 'trader'
  end

  def infrastructure?
    role == 'infrastructure'
  end

  def analyst?
    role == 'analyst'
  end

  def active?
    status == 'active'
  end

  def to_s
    agent_id
  end
end
