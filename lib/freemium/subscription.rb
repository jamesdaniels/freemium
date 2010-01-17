# == Attributes
#   subscribable:         the model in your system that has the subscription. probably a User.
#   subscription_plan:    which service plan this subscription is for. affects how payment is interpreted.
#   paid_through:         when the subscription currently expires, assuming no further payment. for manual billing, this also determines when the next payment is due.
#   billing_key:          the id for this user in the remote billing gateway. may not exist if user is on a free plan.
#   last_transaction_at:  when the last gateway transaction was for this account. this is used by your gateway to find "new" transactions.
#
module Freemium
  module Subscription
    include Rates
        
    def self.included(base)
      base.class_eval do
        belongs_to :subscription_plan, :class_name => "FreemiumSubscriptionPlan"
        belongs_to :subscribable, :polymorphic => true
        belongs_to :credit_card, :dependent => :destroy, :class_name => "FreemiumCreditCard"
        has_many :coupon_redemptions, :conditions => "freemium_coupon_redemptions.expired_on IS NULL", :class_name => "FreemiumCouponRedemption", :foreign_key => :subscription_id, :dependent => :destroy
        has_many :coupons, :through => :coupon_redemptions, :conditions => "freemium_coupon_redemptions.expired_on IS NULL"
  
				default_scope :select => '`freemium_subscriptions`.*'

        # Auditing
        has_many :transactions, :class_name => "FreemiumTransaction", :foreign_key => :subscription_id
              
        named_scope :paid, :include => [:subscription_plan], :conditions => "freemium_subscription_plans.rate_cents > 0"
        named_scope :due, :conditions =>  ['paid_through <= ?', Date.today] # could use the concept of a next retry date
        named_scope :expired, :conditions => ['(expire_on >= paid_through OR paid_through IS NULL) AND expire_on <= ?', Date.today]
              
				before_validation :set_subscription_plan
        before_validation :set_paid_through
        before_validation :set_started_on
        before_validation :switch_to_original_card
        before_save :store_credit_card_offsite
        before_save :discard_credit_card_unless_paid
        before_destroy :cancel_in_remote_system
        
        after_create :audit_create
        after_update :audit_update
        after_destroy :audit_destroy
           
        # validates_presence_of :subscribable
        # validates_associated :subscribable
        validates_presence_of :subscription_plan
        validates_presence_of :paid_through, :if => :paid? 
        validates_presence_of :started_on
        validates_presence_of :credit_card, :if => :paid?
        validates_associated :credit_card#, :if => :paid?

				accepts_nested_attributes_for :credit_card, :reject_if => :reject_card?
      end
      base.extend ClassMethods
    end
    
    def original_credit_card_id
    end
    
    def original_credit_card_id=(new_value)
      @original_credit_card_id = new_value
    end
    
    def original_plan
      @original_plan ||= FreemiumSubscriptionPlan.find(self.changes["subscription_plan_id"].first) if subscription_plan_id_changed?
    end
    
    def use_existing_card
      @use_existing_card || true
    end
    
    def use_existing_card=(new_value)
      @use_existing_card = new_value
    end
    
    ##
    ## Callbacks
    ##
    
    protected

    def switch_to_original_card
      if @use_existing_card && @use_existing_card == '1' && @original_credit_card_id
        self.credit_card = FreemiumCreditCard.find(@original_credit_card_id)
      end
      true
    end
    
    def reject_card?
      @use_existing_card && @use_existing_card == '1'
    end

		def set_subscription_plan
			self.subscription_plan = FreemiumSubscriptionPlan.find(subscription_plan_id) if subscription_plan.nil? && subscription_plan_id?
		end

    def set_paid_through
      if subscription_plan_id_changed? && !paid_through_changed?
        if paid?
          if new_record?
            # paid + new subscription = in free trial
            self.paid_through = Date.today + Freemium.days_free_trial
            self.in_trial = true
          elsif !self.in_trial? && self.original_plan && self.original_plan.paid?
            # paid + not in trial + not new subscription + original sub was paid = calculate and credit for remaining value
            value = self.remaining_value(original_plan)
            self.paid_through = Date.today
            self.credit(value)
          else
            # otherwise payment is due today
            self.paid_through = Date.today
            self.in_trial = false
          end
        else
          # free plans don't pay
          self.paid_through = nil
        end
      end
      true
    end    

    def set_started_on
      self.started_on = Date.today if subscription_plan_id_changed?
    end

    # Simple assignment of a credit card. Note that this may not be
    # useful for your particular situation, especially if you need
    # to simultaneously set up automated recurrences.
    #
    # Because of the third-party interaction with the gateway, you
    # need to be careful to only use this method when you expect to
    # be able to save the record successfully. Otherwise you may end
    # up storing a credit card in the gateway and then losing the key.
    #
    # NOTE: Support for updating an address could easily be added
    # with an "address" property on the credit card.
    def store_credit_card_offsite
      if credit_card && credit_card.changed? && credit_card.valid? 
        response = billing_key ? Freemium.gateway.update(billing_key, credit_card, credit_card.address, subscribable) : Freemium.gateway.store(credit_card, credit_card.address, subscribable)
        raise Freemium::CreditCardStorageError.new(response.message) unless response.success?
        self.billing_key = response.billing_key
        self.expire_on = nil
        self.credit_card.reload # to prevent needless subsequent store() calls
      end
    end
    
    def discard_credit_card_unless_paid
      unless paid?
        credit_card.destroy if credit_card
        cancel_in_remote_system
      end
    end
    
    def cancel_in_remote_system
      if billing_key
        Freemium.gateway.cancel(self.billing_key)
        self.billing_key = nil
      end
    end
    
    ##
    ## Callbacks :: Auditing
    ##    
    
    def audit_create
      FreemiumSubscriptionChange.create(:reason => "new", 
                                        :subscribable => self.subscribable,
                                        :new_subscription_plan_id => self.subscription_plan_id,
                                        :new_rate => self.rate,
                                        :original_rate => Money.empty)
    end
    
    def audit_update
      if self.subscription_plan_id_changed?
        return if self.original_plan.nil?
        reason = self.original_plan.rate > self.subscription_plan.rate ? (self.expired? ? "expiration" : "downgrade") : "upgrade"
        FreemiumSubscriptionChange.create(:reason => reason,
                                          :subscribable => self.subscribable,
                                          :original_subscription_plan_id => self.original_plan.id,
                                          :original_rate => self.rate(:plan => self.original_plan),
                                          :new_subscription_plan_id => self.subscription_plan.id,
                                          :new_rate => self.rate)
      end
    end
    
    def audit_destroy
      FreemiumSubscriptionChange.create(:reason => "cancellation", 
                                        :subscribable => self.subscribable,
                                        :original_subscription_plan_id => self.subscription_plan_id,
                                        :original_rate => self.rate,
                                        :new_rate => Money.empty)
    end
    
    public
    
    ##
    ## Class Methods
    ##
    
    module ClassMethods
      # expires all subscriptions that have been pastdue for too long (accounting for grace)
      def expire
        self.expired.select{|s| s.paid?}.each(&:expire!)
      end      
    end
    
    ##
    ## Rate
    ##
    
    def rate(options = {})
      options = {:date => Date.today, :plan => self.subscription_plan}.merge(options)
      
      return nil unless options[:plan]
      value = options[:plan].rate
      value = self.coupon(options[:date]).discount(value) if self.coupon(options[:date])
      value
    end
    
    def paid?
      return false unless rate
      rate.cents > 0
    end  
    
    ##
    ## Coupon Redemption
    ##
    
    def coupon_key=(coupon_key)
      @coupon_key = coupon_key ? coupon_key.downcase : nil
      self.coupon = FreemiumCoupon.find_by_redemption_key(@coupon_key) unless @coupon_key.blank?
    end
    
    def validate
      self.errors.add :coupon, "could not be found for '#{@coupon_key}'" if !@coupon_key.blank? && FreemiumCoupon.find_by_redemption_key(@coupon_key).nil?
    end
      
    def coupon=(coupon)
      if coupon
        s = FreemiumCouponRedemption.new(:subscription => self, :coupon => coupon)
        coupon_redemptions << s
      end
    end
    
    def coupon(date = Date.today)
      coupon_redemption(date).coupon rescue nil
    end

    def coupon_redemption(date = Date.today)
      return nil if coupon_redemptions.empty?
      active_coupons = coupon_redemptions.select{|c| c.active?(date)}
      return nil if active_coupons.empty?
      active_coupons.sort_by{|c| c.coupon.discount_percentage }.reverse.first
    end

    ##
    ## Remaining Time
    ##

    # returns the value of the time between now and paid_through.
    # will optionally interpret the time according to a certain subscription plan.
    def remaining_value(plan = self.subscription_plan)
      self.daily_rate(:plan => plan) * remaining_days
    end

    # if paid through today, returns zero
    def remaining_days
      self.paid_through - Date.today
    end

    ##
    ## Grace Period
    ##

    # if under grace through today, returns zero
    def remaining_days_of_grace
      self.expire_on - Date.today - 1
    end

    def in_grace?
      remaining_days < 0 and not expired?
    end

    ##
    ## Expiration
    ##

    # sets the expiration for the subscription based on today and the configured grace period.
    def expire_after_grace!(transaction = nil)
      return unless self.expire_on.nil? # You only set this once subsequent failed transactions shouldn't affect expiration
      self.expire_on = [Date.today, paid_through].max + Freemium.days_grace
      transaction.message = "now set to expire on #{self.expire_on}" if transaction
      Freemium.mailer.deliver_expiration_warning(self)
      save!
    end

    # sends an expiration email, then downgrades to a free plan
    def expire!
      Freemium.mailer.deliver_expiration_notice(self)
      # downgrade to a free plan
      self.destroy
    end

    def expired?
      expire_on and expire_on <= Date.today
    end
    
    ##
    ## Receiving More Money
    ##

    # receives payment and saves the record
    def receive_payment!(transaction)
      receive_payment(transaction)
      self.save!
    end

    # extends the paid_through period according to how much money was received.
    # when possible, avoids the days-per-month problem by checking if the money
    # received is a multiple of the plan's rate.
    #
    # really, i expect the case where the received payment does not match the
    # subscription plan's rate to be very much an edge case.
    def receive_payment(transaction)
      self.credit(transaction.amount)
      self.save!
      transaction.subscription.reload  # reloaded to that the paid_through date is correct
      transaction.message = "now paid through #{self.paid_through}"
      
      begin
        Freemium.mailer.deliver_invoice(transaction)
      rescue => e
        transaction.message = "error sending invoice"
      end
    end
    
    def credit(amount)
      self.paid_through += 30.days
      self.expire_on = nil
      self.in_trial = false      
    end

  end
end