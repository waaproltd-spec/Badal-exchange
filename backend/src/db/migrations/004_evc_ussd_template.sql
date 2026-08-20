-- EVC Plus "Dial to Pay": the customer app auto-dials a tel: URI built from
-- this template right after creating a deposit order, same "*712*{number}*{amount}#"
-- pattern used elsewhere in the Dalab product family. Stored in the existing
-- generic config_json column (non-secret) so an admin can update it later
-- without a code deploy -- see paymentIntegrationService.updateIntegrationConfig.
INSERT INTO payment_integrations (provider, status, config_json)
VALUES ('evc_plus', 'inactive', '{"ussd_template": "*712*610346060*{amount}#"}'::jsonb)
ON CONFLICT (provider) DO UPDATE
  SET config_json = payment_integrations.config_json || '{"ussd_template": "*712*610346060*{amount}#"}'::jsonb;
