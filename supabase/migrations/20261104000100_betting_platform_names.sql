-- Betting platform names may start with a digit (888starz, 1Win, 22Bet ...).
--
-- manage_create_betting_platform turned the typed name into a key (lower case,
-- letters and digits only) and refused a key that did not start with a letter,
-- so "888 starz admin" (key 888starzadmin) was refused with "The name must start
-- with a letter". The key is only ever used as text and as a Postgres enum
-- label, both fine for a leading digit. Now: 2 to 30 letters or digits (spaces
-- and punctuation are ignored) with at least one letter. Everything else in the
-- function (existing names refused, a removed never-used name revived, audit)
-- is untouched: the live definition is read and only that rule is replaced.
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.manage_create_betting_platform(text,text)'::regprocedure);
  v_rule constant text := 'IF v_key !~ ''^[a-z][a-z0-9]{1,29}$'' THEN';
  v_msg constant text := 'The name must start with a letter and contain letters or digits';
BEGIN
  IF position(v_rule IN v_def) = 0 OR position(v_msg IN v_def) = 0 THEN
    RAISE EXCEPTION 'manage_create_betting_platform has changed: the name rule was not found';
  END IF;
  v_def := replace(v_def, v_rule, 'IF v_key !~ ''^[a-z0-9]{2,30}$'' OR v_key !~ ''[a-z]'' THEN');
  v_def := replace(v_def, v_msg, 'The name must be 2 to 30 letters or digits (spaces are ignored), with at least one letter');
  EXECUTE v_def;
END $$;
