-- Real yearly prices (10 months — 2 months free vs monthly × 12).
update public.subscription_plans
set
  yearly_price_cents = case slug
    when 'basic' then 29000
    when 'standard' then 79000
    when 'premium' then 149000
    when 'enterprise' then 499000
    else yearly_price_cents
  end,
  updated_at = now()
where slug in ('basic', 'standard', 'premium', 'enterprise');
