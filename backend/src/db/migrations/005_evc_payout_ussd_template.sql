-- EVC Plus Withdraw "Dial to Pay": the agent app auto-dials a tel: URI built
-- from this template when sending a withdrawal payout, using the standard
-- EVC Plus "send money" USSD code with the order's recipient number and net
-- amount substituted in. Same non-secret config_json field as the deposit
-- collection template (004_evc_ussd_template.sql) -- admin-editable via
-- paymentIntegrationService.updateIntegrationConfig, no PIN or credential
-- ever stored here.
INSERT INTO payment_integrations (provider, status, config_json)
VALUES ('evc_plus', 'inactive', '{"payout_ussd_template": "*712*{number}*{amount}#"}'::jsonb)
ON CONFLICT (provider) DO UPDATE
  SET config_json = payment_integrations.config_json || '{"payout_ussd_template": "*712*{number}*{amount}#"}'::jsonb;
