module Freemium
  module Gateways
    class AuthorizeCim
			attr_accessor :username, :password, :validation_mode
			
      # cancels the subscription identified by the given billing key.
      # this might mean removing it from the remote system, or halting the remote
      # recurring billing.
      #
      # should return a Freemium::Response
      def cancel(billing_key)
        a = ActiveMerchantCall.new(:login => username, :password => password)
				a.interact('delete_customer_profile', {:customer_profile_id => billing_key})
				return a.response
		  end

      # stores a credit card with the gateway.
      # should return a Freemium::Response
      def store(credit_card, address = nil, user = nil)
				a = ActiveMerchantCall.new(:login => username, :password => password, :user => user)
        a.interact('create_customer_profile', {
		      :profile => {
						:merchant_customer_id => "#{Time.now.to_i}-#{(rand()*100000).to_i}",
						:payment_profiles => {
					    :customer_type => 'individual',
					    :bill_to => params_for_address(address),
					    :payment => {
							  :credit_card => credit_card
							}
					  }
					}
		    })
				return a.response
      end

      # updates a credit card in the gateway.
      # should return a Freemium::Response
      def update(billing_key, credit_card = nil, address = nil, user = nil)
        a = ActiveMerchantCall.new(:login => username, :password => password, :user => user, :billing_key => billing_key)
        a.interact('update_customer_profile', :profile => {
						:customer_profile_id => user.customer_profile_id,
						:merchant_customer_id => "#{Time.now.to_i}-#{(rand()*100000).to_i}",
					  :payment_profile => {
					  	:customer_payment_profile_id => billing_key,
					  	:payment => {
					  		:credit_card => credit_card
					  	}
					  }
					}
				)
				return a.response
      end

      ##
      ## Only needed to support Freemium.billing_handler = :gateway
      ##

      # only needed to support an ARB module. otherwise, the manual billing process will
      # take care of processing transaction information as it happens.
      #
      # concrete classes need to support these options:
      #   :billing_key : - only retrieve transactions for this specific billing key
      #   :after :       - only retrieve transactions after this datetime (non-inclusive)
      #   :before :      - only retrieve transactions before this datetime (non-inclusive)
      #
      # return value should be a collection of Freemium::Transaction objects.
      def transactions(options = {})
        []
      end

      ##
      ## Only needed to support Freemium.billing_handler = :manual
      ##

      # charges money against the given billing key.
      # should return a Freemium::Transaction
      def charge(billing_key, amount, user = nil)
        a = ActiveMerchantCall.new(:login => username, :password => password, :user => user)
        a.interact('create_customer_profile_transaction', :transaction => {
	        :customer_profile_id => user.customer_profile_id,
	        :customer_payment_profile_id => billing_key,
	        :type => :auth_capture,
					:validation_mode => validation_mode,
	        :amount => (amount.cents/100.0)
	      })
				return FreemiumTransaction.new(:billing_key => billing_key, :amount => amount, :success => a.response.success?, :gateway_message => a.response.message)
      end

			protected

      def params_for_address(address)
        {
	        :email    => address && address.email   || '',
	        :address1 => address && address.street  || '',
	        :city     => address && address.city    || '',
	        :state    => address && address.state   || '', # TODO: two-digit code!
	        :zip      => address && address.zip     || '',
	        :country  => address && address.country || ''  # TODO: two digit code! (ISO-3166)
	      }
      end

      class ActiveMerchantCall
        attr_accessor :gateway, :user, :billing_key
        attr_reader :response

        def initialize(params = {})
					self.user = params[:user]
					self.billing_key = params[:billing_key]
					self.gateway = ActiveMerchant::Billing::AuthorizeNetCimGateway.new(params)
        end

        def interact(method_name, params = {})
          data = gateway.method(method_name).call(params)
          success = (data.message == 'Successful.' || data.params['direct_response'] && (data.params['direct_response']['message'] == "This transaction has been approved." || data.params['direct_response']['message'] == "Successful.")) || false
          @response = Freemium::Response.new(success, data)
          @response.billing_key = data.params['customer_payment_profile_id'] || data.params['customer_payment_profile_id_list'] && data.params['customer_payment_profile_id_list']['numeric_string'] || billing_key
          unless user.nil? || user.customer_profile_id
						user.customer_profile_id = data.authorization
						user.save
					end
          @response.message = data.message
          return self
        end

      end
    end
  end
end