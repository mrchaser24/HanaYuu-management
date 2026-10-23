-- Cash shifts, approved cash movements, corrections, expenses, and
-- owner review of offline conflicts.

create or replace function public.shift_expected_cash(p_shift_id uuid)
returns integer
language sql stable security definer set search_path = public
as $$
  select (coalesce(s.opening_cash_centavos, 0)
    + coalesce((
        select sum(o.total_centavos)
        from public.orders o
        join public.payments p on p.order_id = o.id
        where o.shift_id = p_shift_id
          and p.method = 'cash'
          and o.status in ('completed', 'refunded', 'voided')
      ), 0)
    - coalesce((
        select sum(r.total_centavos)
        from public.order_reversals r
        join public.orders o on o.id = r.order_id
        where o.shift_id = p_shift_id and r.refund_method = 'cash'
      ), 0)
    - coalesce((
        select sum(cm.amount_centavos) from public.cash_movements cm where cm.shift_id = p_shift_id
      ), 0))::integer
  from public.cash_shifts s where s.id = p_shift_id;
$$;

create or replace function public.open_shift(
  p_branch_id uuid,
  p_opening_cash_centavos integer
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_shift_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_opening_cash_centavos is null or p_opening_cash_centavos < 0 then raise exception 'Opening cash cannot be negative'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;

  if exists (
    select 1 from public.cash_shifts
    where branch_id = p_branch_id and cashier_id = auth.uid() and closed_at is null
  ) then raise exception 'You already have an open shift at this branch'; end if;

  insert into public.cash_shifts (branch_id, cashier_id, opening_cash_centavos, status)
  values (p_branch_id, auth.uid(), p_opening_cash_centavos, 'open')
  returning id into v_shift_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'shift_opened', 'cash_shift', v_shift_id,
    jsonb_build_object('opening_cash_centavos', p_opening_cash_centavos));
  return v_shift_id;
end;
$$;

create or replace function public.close_shift(
  p_shift_id uuid,
  p_counted_cash_centavos integer,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_expected integer;
  v_over_short integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_counted_cash_centavos is null or p_counted_cash_centavos < 0 then raise exception 'Counted cash cannot be negative'; end if;
  select * into v_shift from public.cash_shifts where id = p_shift_id for update;
  if not found then raise exception 'Shift not found'; end if;
  v_branch_id := v_shift.branch_id;
  if not (v_shift.cashier_id = auth.uid() or public.can_manage_branch(v_branch_id)) then
    raise exception 'Shift access denied';
  end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  if v_shift.closed_at is not null then
    return jsonb_build_object(
      'shift_id', v_shift.id, 'expected_cash_centavos', v_shift.expected_cash_centavos,
      'counted_cash_centavos', v_shift.counted_cash_centavos, 'over_short_centavos', v_shift.over_short_centavos,
      'closed_at', v_shift.closed_at
    );
  end if;

  v_expected := public.shift_expected_cash(p_shift_id);
  v_over_short := p_counted_cash_centavos - v_expected;

  update public.cash_shifts set
    closed_at = now(), closed_by = auth.uid(), counted_cash_centavos = p_counted_cash_centavos,
    expected_cash_centavos = v_expected, over_short_centavos = v_over_short,
    note = nullif(trim(p_note), ''), status = 'closed', version = version + 1
  where id = p_shift_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'shift_closed', 'cash_shift', p_shift_id,
    jsonb_build_object('expected_cash_centavos', v_expected, 'counted_cash_centavos', p_counted_cash_centavos,
      'over_short_centavos', v_over_short));

  return jsonb_build_object(
    'shift_id', p_shift_id, 'expected_cash_centavos', v_expected,
    'counted_cash_centavos', p_counted_cash_centavos, 'over_short_centavos', v_over_short,
    'closed_at', now()
  );
end;
$$;

create or replace function public.request_cash_movement(
  p_shift_id uuid,
  p_request_id uuid,
  p_kind text,
  p_amount_centavos integer,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_shift public.cash_shifts%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_kind not in ('payout', 'safe_drop') then raise exception 'Invalid cash movement kind'; end if;
  if p_amount_centavos is null or p_amount_centavos <= 0 then raise exception 'Amount must be positive'; end if;
  if p_reason is null or char_length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;

  select * into v_shift from public.cash_shifts where id = p_shift_id for update;
  if not found then raise exception 'Shift not found'; end if;
  if v_shift.closed_at is not null then raise exception 'Shift is closed'; end if;
  if not (v_shift.cashier_id = auth.uid() or public.can_manage_branch(v_shift.branch_id)) then
    raise exception 'Shift access denied';
  end if;
  v_branch_id := v_shift.branch_id;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  insert into public.cash_movement_requests (
    shift_id, requested_by, kind, amount_centavos, reason, status, request_id
  ) values (
    p_shift_id, auth.uid(), p_kind, p_amount_centavos, trim(p_reason), 'pending', p_request_id
  ) returning id into v_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'cash_movement_requested', 'cash_movement_request', v_id,
    jsonb_build_object('kind', p_kind, 'amount_centavos', p_amount_centavos));
  return v_id;
end;
$$;

create or replace function public.review_cash_movement(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_req public.cash_movement_requests%rowtype;
  v_shift public.cash_shifts%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_movement_id uuid;
  v_expected integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_req from public.cash_movement_requests where request_id = p_request_id for update;
  if not found then
    select * into v_req from public.cash_movement_requests where id = p_request_id for update;
  end if;
  if not found then raise exception 'Cash request not found'; end if;
  if v_req.status <> 'pending' then
    return v_req.applied_movement_id;
  end if;

  select * into v_shift from public.cash_shifts where id = v_req.shift_id for update;
  if not found then raise exception 'Shift not found'; end if;
  v_branch_id := v_shift.branch_id;
  if not public.can_manage_branch(v_branch_id) then raise exception 'Approval access denied'; end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  if not p_approve then
    update public.cash_movement_requests set
      status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(p_note), ''),
      approved_by = auth.uid(), approved_at = now()
    where id = v_req.id;
    insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'cash_movement_rejected', 'cash_movement_request', v_req.id,
      jsonb_build_object('reason', p_note));
    return null;
  end if;

  if v_shift.closed_at is not null then raise exception 'Shift is closed'; end if;
  if v_req.kind not in ('payout', 'safe_drop') then raise exception 'Invalid cash movement kind'; end if;
  v_expected := public.shift_expected_cash(v_shift.id);
  if v_req.amount_centavos > v_expected then
    raise exception 'Cash movement exceeds expected drawer cash';
  end if;

  insert into public.cash_movements (
    shift_id, request_id, kind, amount_centavos, created_by, approved_by
  ) values (
    v_shift.id, v_req.request_id, v_req.kind, v_req.amount_centavos, v_req.requested_by, auth.uid()
  ) returning id into v_movement_id;

  update public.cash_movement_requests set
    status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
    review_note = nullif(trim(p_note), ''), approved_by = auth.uid(), approved_at = now(),
    applied_movement_id = v_movement_id
  where id = v_req.id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'cash_movement_approved', 'cash_movement_request', v_req.id,
    jsonb_build_object('movement_id', v_movement_id, 'amount_centavos', v_req.amount_centavos));
  return v_movement_id;
end;
$$;

create or replace function public.record_expense(
  p_branch_id uuid,
  p_category text,
  p_description text,
  p_amount_centavos integer,
  p_paid_from_cash boolean default false,
  p_cash_movement_id uuid default null,
  p_spent_at timestamptz default now()
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_amount_centavos is null or p_amount_centavos <= 0 then raise exception 'Expense amount must be positive'; end if;
  if p_category is null or char_length(trim(p_category)) < 2 then raise exception 'A category is required'; end if;
  if p_description is null or char_length(trim(p_description)) < 3 then raise exception 'A description is required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;

  if p_cash_movement_id is not null then
    if not exists (
      select 1 from public.cash_movements cm
      join public.cash_shifts cs on cs.id = cm.shift_id
      where cm.id = p_cash_movement_id and cs.branch_id = p_branch_id
    ) then raise exception 'Cash payout does not belong to this branch'; end if;
  end if;

  insert into public.expenses (
    branch_id, category, description, amount_centavos, paid_from_cash, cash_movement_id, spent_at, created_by
  ) values (
    p_branch_id, trim(p_category), trim(p_description), p_amount_centavos,
    coalesce(p_paid_from_cash, false), p_cash_movement_id, coalesce(p_spent_at, now()), auth.uid()
  ) returning id into v_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'expense_recorded', 'expense', v_id,
    jsonb_build_object('amount_centavos', p_amount_centavos, 'category', p_category));
  return v_id;
end;
$$;

create or replace function public.request_correction(
  p_order_id uuid,
  p_kind public.correction_kind,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_reason is null or char_length(trim(p_reason)) < 3 then raise exception 'A reason is required'; end if;
  select * into v_order from public.orders where id = p_order_id;
  if not found then raise exception 'Order not found'; end if;
  v_branch_id := v_order.branch_id;
  if not public.can_access_branch(v_branch_id) then raise exception 'Branch access denied'; end if;
  if v_order.status <> 'completed' then raise exception 'Only completed orders can be corrected'; end if;
  if exists (select 1 from public.order_reversals where order_id = p_order_id) then raise exception 'Order is already reversed'; end if;
  if exists (select 1 from public.order_corrections where order_id = p_order_id and status = 'pending') then
    raise exception 'A correction is already pending for this order';
  end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  insert into public.order_corrections (order_id, branch_id, kind, reason, status, requested_by)
  values (p_order_id, v_branch_id, p_kind, trim(p_reason), 'pending', auth.uid())
  returning id into v_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'correction_requested', 'order_correction', v_id,
    jsonb_build_object('order_id', p_order_id, 'kind', p_kind));
  return v_id;
end;
$$;

create or replace function public.review_correction(
  p_correction_id uuid,
  p_approve boolean,
  p_note text default null,
  p_refund_method public.payment_kind default null,
  p_refund_reference text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_corr public.order_corrections%rowtype;
  v_order public.orders%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_cons record;
  v_balance public.ingredient_balances%rowtype;
  v_finished public.finished_goods_balances%rowtype;
  v_new_qty numeric(14,3);
  v_new_avg numeric(18,6);
  v_reversal_id uuid;
  v_refund_method public.payment_kind;
  v_cost integer := 0;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_corr from public.order_corrections where id = p_correction_id for update;
  if not found then raise exception 'Correction not found'; end if;
  if v_corr.status <> 'pending' then return v_corr.reversal_id; end if;
  select * into v_order from public.orders where id = v_corr.order_id for update;
  if not found then raise exception 'Order not found'; end if;
  v_branch_id := v_corr.branch_id;
  if not public.can_manage_branch(v_branch_id) then raise exception 'Approval access denied'; end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  if not p_approve then
    update public.order_corrections set
      status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(trim(p_note), '')
    where id = v_corr.id;
    insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'correction_rejected', 'order_correction', v_corr.id,
      jsonb_build_object('reason', p_note));
    return null;
  end if;

  if exists (select 1 from public.order_reversals where order_id = v_order.id) then
    raise exception 'Order is already reversed';
  end if;
  if v_order.status <> 'completed' then
    raise exception 'Order cannot be reversed in its current state';
  end if;

  for v_cons in
    select c.* from public.order_line_consumptions c
    join public.order_lines l on l.id = c.order_line_id
    where l.order_id = v_order.id
  loop
    if v_cons.ingredient_id is not null then
      insert into public.ingredient_balances (branch_id, ingredient_id, quantity, average_cost_centavos)
      values (v_branch_id, v_cons.ingredient_id, 0, 0)
      on conflict (branch_id, ingredient_id) do nothing;
      select * into v_balance from public.ingredient_balances
      where branch_id = v_branch_id and ingredient_id = v_cons.ingredient_id for update;
      v_new_qty := v_balance.quantity + v_cons.quantity;
      v_new_avg := ((v_balance.quantity * v_balance.average_cost_centavos) + (v_cons.quantity * v_cons.unit_cost_centavos)) / v_new_qty;
      update public.ingredient_balances
        set quantity = v_new_qty, average_cost_centavos = v_new_avg, version = version + 1
        where branch_id = v_branch_id and ingredient_id = v_cons.ingredient_id;
    else
      insert into public.finished_goods_balances (branch_id, product_id, quantity, average_cost_centavos)
      values (v_branch_id, v_cons.product_id, 0, 0)
      on conflict (branch_id, product_id) do nothing;
      select * into v_finished from public.finished_goods_balances
      where branch_id = v_branch_id and product_id = v_cons.product_id for update;
      v_new_qty := v_finished.quantity + v_cons.quantity;
      v_new_avg := ((v_finished.quantity * v_finished.average_cost_centavos) + (v_cons.quantity * v_cons.unit_cost_centavos)) / v_new_qty;
      update public.finished_goods_balances
        set quantity = v_new_qty, average_cost_centavos = v_new_avg, version = version + 1
        where branch_id = v_branch_id and product_id = v_cons.product_id;
    end if;

    insert into public.inventory_movements (
      branch_id, ingredient_id, product_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
    ) values (
      v_branch_id, v_cons.ingredient_id, v_cons.product_id, 'reversal',
      v_cons.quantity, v_cons.unit_cost_centavos, v_order.id, auth.uid()
    );
  end loop;

  select coalesce(sum(cost_snapshot_centavos), 0) into v_cost from public.order_lines where order_id = v_order.id;
  select coalesce(p_refund_method, p.method) into v_refund_method
  from public.payments p where p.order_id = v_order.id;
  if v_refund_method is null then v_refund_method := coalesce(p_refund_method, 'cash'); end if;

  insert into public.order_reversals (
    order_id, correction_id, branch_id, total_centavos, cost_centavos,
    refund_method, refund_reference, created_by
  ) values (
    v_order.id, v_corr.id, v_branch_id, v_order.total_centavos, v_cost,
    v_refund_method, nullif(trim(p_refund_reference), ''), auth.uid()
  ) returning id into v_reversal_id;

  update public.order_corrections set
    status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(),
    review_note = nullif(trim(p_note), ''), reversal_id = v_reversal_id,
    refund_method = v_refund_method, refund_reference = nullif(trim(p_refund_reference), ''),
    refund_amount_centavos = v_order.total_centavos
  where id = v_corr.id;

  update public.orders set
    status = case when v_corr.kind = 'void' then 'voided'::public.order_status else 'refunded'::public.order_status end,
    reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = v_order.id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'correction_approved', 'order_correction', v_corr.id,
    jsonb_build_object('order_id', v_order.id, 'reversal_id', v_reversal_id, 'refund_method', v_refund_method));
  return v_reversal_id;
end;
$$;

create or replace function public.review_review_order(
  p_order_id uuid,
  p_action text,
  p_reason text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_branch_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_shop_settings public.shop_settings%rowtype;
  v_method public.payment_methods%rowtype;
  v_line public.order_lines%rowtype;
  v_req record;
  v_balance public.ingredient_balances%rowtype;
  v_finished public.finished_goods_balances%rowtype;
  v_line_cost integer;
  v_estimated boolean;
  v_tax integer := 0;
  v_tendered integer;
  v_change integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_action not in ('approve', 'void', 'reject') then raise exception 'Invalid review action'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status <> 'needs_review' then raise exception 'Order is not awaiting review'; end if;
  v_branch_id := v_order.branch_id;
  if not public.can_manage_branch(v_branch_id) then raise exception 'Review access denied'; end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_branch_id;

  if p_action in ('void', 'reject') then
    update public.orders set
      status = case when p_action = 'void' then 'voided'::public.order_status else 'rejected'::public.order_status end,
      reviewed_by = auth.uid(), reviewed_at = now(), review_reason = coalesce(review_reason || ' | ', '') || coalesce(nullif(trim(p_reason), ''), p_action),
      updated_at = now()
    where id = p_order_id;
    update public.sync_requests set sync_state = 'rejected', status = 'rejected', error_detail = coalesce(p_reason, error_detail), updated_at = now()
      where device_id = v_order.device_id and request_id = v_order.request_id;
    insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
    values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'review_order_' || p_action, 'order', p_order_id,
      jsonb_build_object('reason', p_reason));
    return p_order_id;
  end if;

  select * into v_shop_settings from public.shop_settings where shop_id = v_shop_id;
  if not found then
    v_shop_settings.tax_inclusive_enabled := false;
    v_shop_settings.tax_rate_bps := 0;
  end if;
  select * into v_method from public.payment_methods where id = v_order.payment_method_id;
  if not found then raise exception 'Payment method is unavailable'; end if;

  for v_req in
    select req.ingredient_id, i.name, sum(req.required) as required
    from (
      select r.ingredient_id, r.quantity * ol.quantity as required
      from public.order_lines ol
      join public.product_recipes r on r.product_id = ol.product_id
      where ol.order_id = p_order_id and ol.stock_model = 'made_to_order'
      union all
      select por.ingredient_id, por.quantity * ol.quantity
      from public.order_lines ol
      join public.order_line_options olo on olo.order_line_id = ol.id
      join public.product_option_recipes por on por.option_id = olo.option_id
      where ol.order_id = p_order_id and ol.stock_model = 'made_to_order'
    ) req
    join public.ingredients i on i.id = req.ingredient_id
    group by req.ingredient_id, i.name order by req.ingredient_id
  loop
    select * into v_balance from public.ingredient_balances
    where branch_id = v_branch_id and ingredient_id = v_req.ingredient_id for update;
    if not found or v_balance.quantity < v_req.required then
      raise exception 'Insufficient ingredient stock for %. Restock, then retry approval.', v_req.name;
    end if;
  end loop;

  for v_req in
    select ol.product_id, p.name, sum(ol.quantity) as required
    from public.order_lines ol join public.products p on p.id = ol.product_id
    where ol.order_id = p_order_id and ol.stock_model = 'batch_produced'
    group by ol.product_id, p.name order by ol.product_id
  loop
    select * into v_finished from public.finished_goods_balances
    where branch_id = v_branch_id and product_id = v_req.product_id for update;
    if not found or v_finished.quantity < v_req.required then
      raise exception 'Insufficient finished stock for %. Produce a batch, then retry approval.', v_req.name;
    end if;
  end loop;

  for v_line in select * from public.order_lines where order_id = p_order_id loop
    v_line_cost := 0;
    v_estimated := false;
    if v_line.stock_model = 'made_to_order' then
      if not exists (select 1 from public.product_recipes where product_id = v_line.product_id) then
        v_estimated := true;
      end if;
      insert into public.order_line_consumptions (order_line_id, ingredient_id, quantity, unit_cost_centavos, source)
      select v_line.id, r.ingredient_id, r.quantity * v_line.quantity, coalesce(ib.average_cost_centavos, 0), 'recipe'
      from public.product_recipes r
      left join public.ingredient_balances ib on ib.branch_id = v_branch_id and ib.ingredient_id = r.ingredient_id
      where r.product_id = v_line.product_id;
      insert into public.order_line_consumptions (order_line_id, ingredient_id, quantity, unit_cost_centavos, source)
      select v_line.id, por.ingredient_id, por.quantity * v_line.quantity, coalesce(ib.average_cost_centavos, 0), 'option'
      from public.order_line_options olo
      join public.product_option_recipes por on por.option_id = olo.option_id
      left join public.ingredient_balances ib on ib.branch_id = v_branch_id and ib.ingredient_id = por.ingredient_id
      where olo.order_line_id = v_line.id;
      for v_req in
        select ingredient_id, sum(quantity) as quantity from public.order_line_consumptions
        where order_line_id = v_line.id group by ingredient_id
      loop
        select * into v_balance from public.ingredient_balances
        where branch_id = v_branch_id and ingredient_id = v_req.ingredient_id;
        update public.ingredient_balances
          set quantity = quantity - v_req.quantity, version = version + 1
          where branch_id = v_branch_id and ingredient_id = v_req.ingredient_id;
        insert into public.inventory_movements (
          branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
        ) values (
          v_branch_id, v_req.ingredient_id, 'sale_consumption', -v_req.quantity,
          v_balance.average_cost_centavos, p_order_id, auth.uid()
        );
      end loop;
      select coalesce(sum(round(quantity * unit_cost_centavos)), 0) into v_line_cost
      from public.order_line_consumptions where order_line_id = v_line.id;
    else
      select * into v_finished from public.finished_goods_balances
      where branch_id = v_branch_id and product_id = v_line.product_id;
      v_line_cost := round(v_finished.average_cost_centavos * v_line.quantity);
      update public.finished_goods_balances
        set quantity = quantity - v_line.quantity, version = version + 1
        where branch_id = v_branch_id and product_id = v_line.product_id;
      insert into public.inventory_movements (
        branch_id, product_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
      ) values (
        v_branch_id, v_line.product_id, 'sale_consumption', -v_line.quantity,
        v_finished.average_cost_centavos, p_order_id, auth.uid()
      );
      insert into public.order_line_consumptions (order_line_id, product_id, quantity, unit_cost_centavos, source)
      values (v_line.id, v_line.product_id, v_line.quantity, v_finished.average_cost_centavos, 'finished_goods');
    end if;
    update public.order_lines set cost_snapshot_centavos = v_line_cost, cost_estimated = v_estimated where id = v_line.id;
  end loop;

  if v_shop_settings.tax_inclusive_enabled and v_shop_settings.tax_rate_bps > 0 then
    v_tax := round(v_order.total_centavos::numeric * v_shop_settings.tax_rate_bps / (10000 + v_shop_settings.tax_rate_bps))::integer;
  end if;

  if v_method.kind = 'cash' then
    v_tendered := coalesce(v_order.tendered_centavos, v_order.total_centavos);
    v_change := greatest(v_tendered - v_order.total_centavos, 0);
  else
    v_tendered := null;
    v_change := null;
  end if;

  update public.orders set
    status = 'completed', tax_centavos = v_tax, tax_rate_bps = v_shop_settings.tax_rate_bps,
    tax_inclusive = v_shop_settings.tax_inclusive_enabled, tendered_centavos = v_tendered,
    change_centavos = v_change, reviewed_by = auth.uid(), reviewed_at = now(),
    review_reason = coalesce(review_reason || ' | ', '') || 'approved: ' || coalesce(nullif(trim(p_reason), ''), 'owner exception'),
    updated_at = now()
  where id = p_order_id;

  insert into public.payments (order_id, method, amount_centavos, reference, payment_method_id, tendered_centavos, change_centavos)
  select p_order_id, v_method.kind, v_order.total_centavos, null,
         v_order.payment_method_id, v_tendered, v_change
  where not exists (select 1 from public.payments where order_id = p_order_id);

  update public.sync_requests set sync_state = 'synced', status = 'completed',
    server_result = jsonb_build_object('order_id', p_order_id), updated_at = now()
    where device_id = v_order.device_id and request_id = v_order.request_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_branch_id, v_shop_id, auth.uid(), 'review_order_approved', 'order', p_order_id,
    jsonb_build_object('reason', p_reason));
  return p_order_id;
end;
$$;

revoke all on function public.shift_expected_cash(uuid) from public;
revoke all on function public.open_shift(uuid, integer) from public;
revoke all on function public.close_shift(uuid, integer, text) from public;
revoke all on function public.request_cash_movement(uuid, uuid, text, integer, text) from public;
revoke all on function public.review_cash_movement(uuid, boolean, text) from public;
revoke all on function public.record_expense(uuid, text, text, integer, boolean, uuid, timestamptz) from public;
revoke all on function public.request_correction(uuid, public.correction_kind, text) from public;
revoke all on function public.review_correction(uuid, boolean, text, public.payment_kind, text) from public;
revoke all on function public.review_review_order(uuid, text, text) from public;

grant execute on function public.open_shift(uuid, integer) to authenticated;
grant execute on function public.close_shift(uuid, integer, text) to authenticated;
grant execute on function public.request_cash_movement(uuid, uuid, text, integer, text) to authenticated;
grant execute on function public.review_cash_movement(uuid, boolean, text) to authenticated;
grant execute on function public.record_expense(uuid, text, text, integer, boolean, uuid, timestamptz) to authenticated;
grant execute on function public.request_correction(uuid, public.correction_kind, text) to authenticated;
grant execute on function public.review_correction(uuid, boolean, text, public.payment_kind, text) to authenticated;
grant execute on function public.review_review_order(uuid, text, text) to authenticated;
