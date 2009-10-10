class SubscriptionMailer < ActionMailer::Base
  self.template_root = File.dirname(__FILE__)

  def invoice(transaction)
    setup_email(transaction.subscription.subscribable)
    @subject              = "Your Invoice"
    @body[:amount]        = transaction.amount
    @body[:subscription]  = transaction.subscription
    @bcc                  = Freemium.admin_report_recipients if Freemium.admin_report_recipients
  end

  def expiration_warning(subscription)
    setup_email(subscription.subscribable)
    @subject              = "Your subscription is set to expire"
    @body[:subscription]  = subscription
    @bcc                  = Freemium.admin_report_recipients if Freemium.admin_report_recipients
  end

  def expiration_notice(subscription)
    setup_email(subscription.subscribable)
    @subject              = "Your subscription has expired"
    @body[:subscription]  = subscription
    @bcc                  = Freemium.admin_report_recipients if Freemium.admin_report_recipients
  end
  
  def admin_report(transactions)
    setup_email(Freemium.admin_report_recipients)
    @amount_charged       = transactions.select{|t| t.success?}.collect{|t| t.amount}.sum
    @subject              = "Billing report (#{@amount_charged} charged)"
    @body[:transactions]  = transactions
    @body[:amount_charged] = @amount_charged
  end

  protected

  def setup_email(user)
    @recipients  = "#{user.respond_to?(:email) ? user.email : user}"
    @from        = APP_CONFIG[:noreply_email]
    @sent_on     = Time.now
    @body[:user] = user
  end
end
