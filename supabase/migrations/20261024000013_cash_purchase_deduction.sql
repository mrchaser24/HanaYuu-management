-- Cash purchase deduction: restocks and expenses can auto-deduct from the open cash drawer.
-- Adds delivery_fee to restocks/expenses and a record_cash_payout RPC for immediate drawer deduction.

alter table public.restocks add column if not exists delivery_fee_centavos integer not null default 0 check (delivery_fee_centavos >= 0);
alter table public.restocks add column if not exists paid_from_cash boolean not null default false;
alter table public.restocks add column if not exists cash_movement_id uuid references public.cash_movements(id) on delete restrict;

alter table public.expenses add column if not exists delivery_fee_centavos integer not null default 0 check (delivery_fee_centavos >= 0);

create or replace function public.record_cash_payout(
  p_shift_id uuid,
  p_amount_centavos integer,
  p_reason text,
  p_request_id uuid
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_request_row_id uuid;
  v_movement_id uuid;
  v_expected integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_amount_centavos is null or p_amount_centavos <= 0 then raise exception 'Deduction amount must be positive'; end if;
  if p_reason is null or char_length(trim(p_reason)) < 3 then raise exception 'Deduction name is required'; end if;

  select * into v_shift from public.cash_shifts where id = p_shift_id for update;
  if not found then raise exception 'Shift not found'; end if;
  if v_shift.closed_at is not null then raise exception 'Shift is closed'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_shift.branch_id;

  if not (v_shift.cashier_id = auth.uid() or public.can_manage_branch(v_shift.branch_id)) then
    raise exception 'Shift access denied';
  end if;

  v_branch_id := v_shift.branch_id;

  v_expected := public.shift_expected_cash(p_shift_id);
  if p_amount_centavos > v_expected then
    raise exception 'Insufficient drawer cash';
  end if;

  insert into public.cash_movement_requests (
    shift_id, requested_by, kind, amount_centavos, reason, status, request_id, approved_by, approved_at
  ) values (
    v_shift.id, auth.uid(), 'payout', p_amount_centavos, trim(p_reason), 'approved', p_request_id,
    auth.uid(), now()
  ) returning id into v_request_row_id;

  insert into public.cash_movements (
    shift_id, request_id, kind, amount_centavos, created_by, approved_by
  ) values (
    v_shift.id, p_request_id, 'payout', p_amount_centavos, auth.uid(), auth.uid()
  ) returning id into v_movement_id;

  update public.cash_movement_requests set applied_movement_id = v_movement_id where id = v_request_row_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'cash_purchase_deducted', 'cash_movement', v_movement_id,
    jsonb_build_object('amount_centavos', p_amount_centavos, 'reason', trim(p_reason), 'shift_id', p_shift_id));

  return v_movement_id;
end;
$$;

create or replace function public.get_purchases(
  p_branch_id uuid,
  p_from date default null,
  p_to date default null
) returns table (
  id uuid,
  type text,
  purchase_date timestamptz,
  supplier_category text,
  description text,
  items text,
  base_cost_centavos integer,
  delivery_fee_centavos integer,
  total_deducted_centavos integer,
  paid_from_cash boolean,
  cash_movement_id uuid,
  created_by_name text
)
language plpgsql security definer set search_path = public
as $$
begin
  return query
  select
    r.id,
    'restock' as type,
    r.created_at as purchase_date,
    coalesce(r.supplier, 'Restock') as supplier_category,
    coalesce(r.note, '') as description,
    coalesce((
      select string_agg(ri.quantity::text || ' × ' || i.name || ' @ ₱' || (ri.unit_cost_centavos / 100.0)::text, ', ')
      from public.restock_items ri
      join public.ingredients i on i.id = ri.ingredient_id
      where ri.restock_id = r.id
    ), '') as items,
    r.total_cost_centavos as base_cost_centavos,
    r.delivery_fee_centavos as delivery_fee_centavos,
    r.total_cost_centavos + r.delivery_fee_centavos as total_deducted_centavos,
    r.paid_from_cash as paid_from_cash,
    r.cash_movement_id as cash_movement_id,
    p.display_name as created_by_name
  from public.restocks r
  left join public.profiles p on p.id = r.created_by
  where r.branch_id = p_branch_id
    and (p_from is null or r.created_at >= p_from)
    and (p_to is null or r.created_at < p_to + interval '1 day')

  union all

  select
    e.id,
    'expense' as type,
    e.spent_at as purchase_date,
    e.category as supplier_category,
    e.description as description,
    '' as items,
    e.amount_centavos as base_cost_centavos,
    e.delivery_fee_centavos as delivery_fee_centavos,
    e.amount_centavos + e.delivery_fee_centavos as total_deducted_centavos,
    e.paid_from_cash as paid_from_cash,
    e.cash_movement_id as cash_movement_id,
    p.display_name as created_by_name
  from public.expenses e
  left join public.profiles p on p.id = e.created_by
  where e.branch_id = p_branch_id
    and (p_from is null or e.spent_at >= p_from)
    and (p_to is null or e.spent_at < p_to + interval '1 day')

  order by purchase_date desc;
end;
$$;
