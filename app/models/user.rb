class User
  include Mongoid::Document
  include Mongoid::Timestamps
  include Chartable
  include Workable

  CURRENCIES = {
    'USD' => '$',
    'EUR' => '€',
    'JPY' => '¥',
    'GBP' => '£',
    'CHF' => 'Fr.'
  }.freeze

  DEFAULT_COLOR      = '#000000'.freeze
  DEFAULT_CURRENCY   = 'USD'.freeze
  DEFAULT_IMAGE_FILE = 'user.png'.freeze
  DEFAULT_VOLUME     = 2
  DEFAULT_TICKING    = false

  # authorization fields (deprecated)
  field :provider,    type: String
  field :uid,         type: String
  field :token,       type: String
  field :gravatar_id, type: String

  field :name,      type: String
  field :email,     type: String
  field :image,     type: String
  field :time_zone, type: String
  field :color,     type: String
  field :volume,    type: Integer
  field :ticking,   type: Boolean

  field :work_hours_per_day,  type: Integer
  field :average_hourly_rate, type: Float
  field :currency,            type: String

  validates :color, format: { with: /\A#[A-Fa-f0-9]{6}\Z/, allow_blank: true }
  validates :volume, numericality: { greater_than_or_equal_to: 0, less_than: 4, allow_blank: true }

  validates :currency, inclusion: { in: CURRENCIES.keys }
  validates :work_hours_per_day, numericality: { greater_than: 0, allow_blank: true }
  validates :average_hourly_rate, numericality: { greater_than: 0, allow_blank: true }

  embeds_many :authorizations
  has_many :tomatoes, dependent: :nullify
  has_many :projects, dependent: :nullify
  has_one :daily_score, inverse_of: :user, foreign_key: :uid, dependent: :nullify
  has_one :weekly_score, inverse_of: :user, foreign_key: :uid, dependent: :nullify
  has_one :monthly_score, inverse_of: :user, foreign_key: :uid, dependent: :nullify
  has_one :overall_score, inverse_of: :user, foreign_key: :uid, dependent: :nullify

  # TODO: this could be a composite index
  # TODO: this should be a unique index (unique: true)
  index 'authorizations.uid': 1
  index 'authorizations.provider': 1

  # TODO: this should be a unique index (unique: true)
  index 'authorizations.token': 1

  def self.find_by_token(token)
    User.where('authorizations.token': token).first
  end

  def self.find_by_omniauth(auth)
    find_by_auth_provider(provider: auth['provider'].to_s, uid: auth['uid'].to_s)
  end

  def self.find_by_auth_provider(provider:, uid:)
    any_of(
      {
        authorizations: {
          '$elemMatch' => { provider: provider, uid: uid }
        }
      },
      provider: provider, uid: uid
    ).first
  end

  def self.create_with_omniauth!(auth)
    user = User.new(omniauth_attributes(auth))
    user.authorizations.build(Authorization.omniauth_attributes(auth))
    user.save!
    user
  end

  def update_omniauth_attributes!(auth)
    # migrate users' data gracefully
    update_attributes!(omniauth_attributes(auth))

    authorization = authorization_by_provider(auth['provider'])
    if authorization
      authorization.update_attributes!(Authorization.omniauth_attributes(auth))
    else
      # merge one more authorization provider
      authorizations.create!(Authorization.omniauth_attributes(auth))
    end
  end

  def self.omniauth_attributes(auth)
    attributes = {}

    if auth['info']
      attributes.merge!(name:  auth['info']['name'],
                        email: auth['info']['email'],
                        image: auth['info']['image'])
    end

    attributes
  end

  def omniauth_attributes(auth)
    attributes = self.class.omniauth_attributes(auth)

    %i[name email].each do |attribute|
      attributes.delete(attribute) if send(attribute).present?
    end

    attributes
  end

  def authorization_by_provider(provider)
    authorizations.where(provider: provider).first
  end

  def self.by_tomatoes(users)
    to_tomatoes_bars(users) do |users_by_tomatoes|
      users_by_tomatoes.try(:size).to_i
    end
  end

  def self.by_day(users)
    to_lines(users) do |users_by_day|
      users_by_day.try(:size).to_i
    end
  end

  def self.total_by_day(users)
    # NOTE: first 1687 users lack of created_at value
    users_count = 1687

    to_lines(users) do |users_by_day|
      users_count += users_by_day.try(:size).to_i
    end
  end

  def color
    color_value = self[:color]
    color_value.present? ? color_value : User::DEFAULT_COLOR
  end

  def volume
    volume_value = self[:volume]
    volume_value.present? ? volume_value : User::DEFAULT_VOLUME
  end

  def ticking
    ticking_value = self[:ticking]
    ticking_value.present? ? ticking_value : User::DEFAULT_TICKING
  end

  def currency
    currency_value = self[:currency]
    currency_value.present? ? currency_value : User::DEFAULT_CURRENCY
  end

  def nickname
    authorizations.first.try(:nickname)
  end

  def image_file
    image_value = self[:image] || authorizations.first.try(:image)
    image_value.present? ? image_value : User::DEFAULT_IMAGE_FILE
  end

  def time_zone
    self[:time_zone] if self[:time_zone].present?
  end

  def currency_unit
    User::CURRENCIES[currency]
  end

  def estimated_revenues
    work_time * Workable::TOMATO_TIME_FACTOR / 60 / 60 * average_hourly_rate.to_f if average_hourly_rate
  end

  def tomatoes_counters
    Hash[%i[day week month].map do |time_period|
      [time_period, tomatoes_counter(time_period)]
    end]
  end

  private

  def tomatoes_counter(time_period)
    tomatoes.after(Time.zone.now.send("beginning_of_#{time_period}")).count
  end
end
