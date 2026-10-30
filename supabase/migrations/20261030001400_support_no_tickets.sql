-- No tickets, no complaint records. "La xiriir Admin" opens a direct Telegram
-- chat with the admin (@Badalexchangeadmin); the bot stores nothing of what the
-- customer says. The ticket table, its numbers and its functions are removed,
-- with whatever was in them. (The chat link -- which customer a Telegram chat
-- belongs to -- and the hourly counters stay: they hold no message text.)
DROP FUNCTION IF EXISTS public.manage_close_support_ticket(uuid);
DROP FUNCTION IF EXISTS public.manage_support_tickets(text);
DROP FUNCTION IF EXISTS public.support_create_ticket(bigint, text);
DROP TABLE IF EXISTS public.support_tickets;
DROP SEQUENCE IF EXISTS public.support_ticket_seq;

DELETE FROM public.support_events WHERE kind = 'ticket';
UPDATE public.support_chats SET state = 'ready' WHERE state = 'awaiting_ticket';

ALTER TABLE public.support_chats DROP CONSTRAINT IF EXISTS support_chats_state_check;
ALTER TABLE public.support_chats ADD CONSTRAINT support_chats_state_check
  CHECK (state IN ('start', 'awaiting_wallet', 'awaiting_contact', 'ready'));
ALTER TABLE public.support_events DROP CONSTRAINT IF EXISTS support_events_kind_check;
ALTER TABLE public.support_events ADD CONSTRAINT support_events_kind_check
  CHECK (kind IN ('wrong_wallet', 'ai'));
