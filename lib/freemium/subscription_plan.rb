# == Attributes
#   subscriptions:      all subscriptions for the plan
#   rate_cents:         how much this plan costs, in cents
#   rate:               how much this plan costs, in Money
#   yearly:             whether this plan cycles yearly or monthly
#
module Freemium
  module SubscriptionPlan
    include Rates
    
    def self.included(base)
      base.class_eval do
        # yes, subscriptions.subscription_plan_id may not be null, but
        # this at least makes the delete not happen if there are any active.
        has_many :subscriptions, :dependent => :nullify, :class_name => "FreemiumSubscription", :foreign_key => :subscription_plan_id
        has_and_belongs_to_many :coupons, :class_name => "FreemiumSubscriptionPlan", 
          :join_table => :freemium_coupons_subscription_plans, :foreign_key => :subscription_plan_id, :association_foreign_key => :coupon_id
        
        composed_of :rate, :class_name => 'Money', :mapping => [ %w(rate_cents cents) ], :allow_nil => true
        
        validates_presence_of :key
        validates_presence_of :name
        validates_presence_of :rate_cents
      end
    end
    
    def features
      Freemium::FeatureSet.find(self.feature_set_id)
    end
    
  end
end