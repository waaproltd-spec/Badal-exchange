-- The Customer App's method grid in the BAARI design's order, with Telesom
-- shown as ZAAD (its mobile-money service): EVC Plus, Golis, ZAAD, eDahab,
-- 1XBET, MELBET, WinWin, DBbet, Betwinner, 888STARZ. The method ids, and
-- every order and setting tied to them, are unchanged.
UPDATE public.payment_methods SET label = 'ZAAD', initials = 'ZA', color = '#EAB308' WHERE method = 'telesom';
UPDATE public.payment_methods m SET sort_order = o.pos
FROM (VALUES ('evc_plus', 0), ('golis', 1), ('telesom', 2), ('edahab', 3), ('onexbet', 4),
             ('melbet', 5), ('winwin', 6), ('dbbet', 7), ('betwinner', 8), ('888starz', 9)) AS o(method, pos)
WHERE m.method::text = o.method;
