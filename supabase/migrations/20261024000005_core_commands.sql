-- Core transactional commands. The client is never trusted with prices, costs,
-- stock, approvals, or role decisions; all are re-read and validated here.

create or replace function public.can_access_shop(target_shop uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.shops s
    join public.memberships m on m.group_id = s.group_id
    where s.id = target_shop
      and m.user_id = auth.uid()
      and (
        m.role = 'super_admin'
        or (m.role = 'owner' and m.shop_id = s.id)
        or (m.role = 'staff' and exists (
          select 1 from public.branches b where b.id = m.branch_id and b.shop_id = s.id
        ))
      )
  );
$$;

create or replace function public.can_manage_shop(target_shop uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and (m.role = 'super_admin' or (m.role = 'owner' and m.shop_id = target_shop))
      and exists (select 1 from public.shops s where s.id = target_shop and s.group_id = m.group_id)
  );
$$;

create or replace function public.can_manage_branch(target_branch uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from public.branches b
    join public.shops s on s.id = b.shop_id
    join public.memberships m on m.group_id = s.group_id
    where b.id = target_branch
      and m.user_id = auth.uid()
      and (m.role = 'super_admin' or (m.role = 'owner' and m.shop_id = s.id))
  );
$$;

create or replace function public.bump_shop_config(target_shop uuid)
returns void
language sql security definer set search_path = public
as $$
  update public.shops set config_revision = config_revision + 1 where id = target_shop;
$$;

drop function if exists public.record_checkout(uuid, uuid, uuid, public.payment_kind, text, jsonb, timestamptz);

create or replace function public.record_checkout(
  p_branch_id uuid,
  p_device_id uuid,
  p_request_id uuid,
  p_payment_method_id uuid,
  p_payment_reference text,
  p_items jsonb,
  p_discount_centavos integer default 0,
  p_discount_reason text default null,
  p_tendered_centavos integer default null,
  p_captured_at timestamptz default now(),
  p_config_revision integer default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_order_id uuid;
  v_existing uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_shift_id uuid;
  v_orderable boolean;
  v_settings public.shop_settings%rowtype;
  v_method public.payment_methods%rowtype;
  v_item jsonb;
  v_option jsonb;
  v_product public.products%rowtype;
  v_option_row public.product_options%rowtype;
  v_line public.order_lines%rowtype;
  v_qty integer;
  v_subtotal integer := 0;
  v_discount integer := coalesce(p_discount_centavos, 0);
  v_total integer;
  v_tax integer := 0;
  v_tendered integer;
  v_change integer;
  v_balance public.ingredient_balances%rowtype;
  v_finished public.finished_goods_balances%rowtype;
  v_req record;
  v_line_cost integer;
  v_estimated boolean;
  v_option_count integer;
  v_line_count integer := 0;
  v_payment_kind public.payment_kind;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_request_id is null then raise exception 'A request id is required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'An order needs at least one item';
  end if;
  if v_discount < 0 then raise exception 'Discount cannot be negative'; end if;
  if v_discount > 0 and (p_discount_reason is null or char_length(trim(p_discount_reason)) < 3) then
    raise exception 'A discount reason is required';
  end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id
  where b.id = p_branch_id;
  if v_shop_id is null or not public.can_access_branch(p_branch_id) then
    raise exception 'Branch access denied';
  end if;

  if p_device_id is not null then
    select true into v_orderable
    from public.branch_devices d
    where d.id = p_device_id and d.branch_id = p_branch_id
      and d.user_id = auth.uid() and d.revoked_at is null;
    if not coalesce(v_orderable, false) then raise exception 'Device is not registered for this branch'; end if;
    update public.branch_devices set last_seen_at = now() where id = p_device_id;
  end if;

  select id into v_existing from public.orders
  where branch_id = p_branch_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;

  select * into v_method from public.payment_methods
  where id = p_payment_method_id and shop_id = v_shop_id and active;
  if not found then raise exception 'Payment method is unavailable'; end if;
  v_payment_kind := v_method.kind;

  select * into v_settings from public.shop_settings where shop_id = v_shop_id;
  if not found then
    v_settings.tax_inclusive_enabled := false;
    v_settings.tax_rate_bps := 0;
  end if;

  select id into v_shift_id
  from public.cash_shifts
  where branch_id = p_branch_id and cashier_id = auth.uid() and closed_at is null
  order by opened_at desc limit 1;

  insert into public.orders (
    branch_id, cashier_id, device_id, request_id, status, total_centavos,
    captured_at, created_at, shift_id, config_revision, offline_captured_at
  ) values (
    p_branch_id, auth.uid(), p_device_id, p_request_id, 'completed', 0,
    coalesce(p_captured_at, now()), now(), v_shift_id, p_config_revision, p_captured_at
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty < 1 then raise exception 'Invalid item quantity'; end if;

    select * into v_product from public.products
    where id = (v_item->>'product_id')::uuid and shop_id = v_shop_id and active;
    if not found then raise exception 'Product is unavailable'; end if;

    if not exists (
      select 1 from public.branch_product_settings bps
      where bps.branch_id = p_branch_id and bps.product_id = v_product.id and bps.available = false
    ) then
      v_orderable := true;
    else
      v_orderable := false;
    end if;
    if not v_orderable then raise exception 'Product is unavailable at this branch'; end if;

    v_option_count := jsonb_array_length(coalesce(v_item->'selected_options', '[]'::jsonb));
    if v_option_count <> v_product.flavor_choices * v_qty then
      raise exception 'Select % option(s) for %', v_product.flavor_choices * v_qty, v_product.name;
    end if;

    insert into public.order_lines (
      order_id, product_id, product_name, unit_price_centavos, quantity,
      cost_snapshot_centavos, selected_options, line_subtotal_centavos,
      stock_model, cost_estimated
    ) values (
      v_order_id, v_product.id, v_product.name, v_product.price_centavos, v_qty,
      0, coalesce(v_item->'selected_options', '[]'::jsonb),
      v_product.price_centavos * v_qty, v_product.stock_model, false
    ) returning * into v_line;

    for v_option in select value from jsonb_array_elements(coalesce(v_item->'selected_options', '[]'::jsonb)) loop
      if (v_option->>'id') is not null then
        select * into v_option_row from public.product_options
        where id = (v_option->>'id')::uuid and product_id = v_product.id and active;
      else
        select * into v_option_row from public.product_options
        where product_id = v_product.id and name = (v_option->>'name') and active;
      end if;
      if not found then raise exception 'A selected option is unavailable for %', v_product.name; end if;
      insert into public.order_line_options (order_line_id, option_id, option_name, unit_cost_centavos)
      values (v_line.id, v_option_row.id, v_option_row.name, 0);
    end loop;

    v_subtotal := v_subtotal + (v_product.price_centavos * v_qty);
    v_line_count := v_line_count + 1;
  end loop;

  if v_line_count = 0 then raise exception 'An order needs at least one item'; end if;
  if v_discount > v_subtotal then raise exception 'Discount cannot exceed the subtotal'; end if;

  -- Lock ingredient balances once, in deterministic order, for made-to-order lines.
  for v_req in
    select req.ingredient_id, i.name, sum(req.required) as required
    from (
      select r.ingredient_id, r.quantity * ol.quantity as required
      from public.order_lines ol
      join public.product_recipes r on r.product_id = ol.product_id
      where ol.order_id = v_order_id and ol.stock_model = 'made_to_order'
      union all
      select por.ingredient_id, por.quantity * ol.quantity as required
      from public.order_lines ol
      join public.order_line_options olo on olo.order_line_id = ol.id
      join public.product_option_recipes por on por.option_id = olo.option_id
      where ol.order_id = v_order_id and ol.stock_model = 'made_to_order'
    ) req
    join public.ingredients i on i.id = req.ingredient_id
    group by req.ingredient_id, i.name
    order by req.ingredient_id
  loop
    select * into v_balance from public.ingredient_balances
    where branch_id = p_branch_id and ingredient_id = v_req.ingredient_id
    for update;
    if not found or v_balance.quantity < v_req.required then
      raise exception 'Insufficient ingredient stock for %', v_req.name;
    end if;
  end loop;

  -- Deduct ingredients and write immutable sale-consumption movements.
  for v_req in
    select req.ingredient_id, i.name, sum(req.required) as required
    from (
      select r.ingredient_id, r.quantity * ol.quantity as required
      from public.order_lines ol
      join public.product_recipes r on r.product_id = ol.product_id
      where ol.order_id = v_order_id and ol.stock_model = 'made_to_order'
      union all
      select por.ingredient_id, por.quantity * ol.quantity as required
      from public.order_lines ol
      join public.order_line_options olo on olo.order_line_id = ol.id
      join public.product_option_recipes por on por.option_id = olo.option_id
      where ol.order_id = v_order_id and ol.stock_model = 'made_to_order'
    ) req
    join public.ingredients i on i.id = req.ingredient_id
    group by req.ingredient_id, i.name
    order by req.ingredient_id
  loop
    select * into v_balance from public.ingredient_balances
    where branch_id = p_branch_id and ingredient_id = v_req.ingredient_id;
    update public.ingredient_balances
      set quantity = quantity - v_req.required, version = version + 1
      where branch_id = p_branch_id and ingredient_id = v_req.ingredient_id;
    insert into public.inventory_movements (
      branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
    ) values (
      p_branch_id, v_req.ingredient_id, 'sale_consumption', -v_req.required,
      v_balance.average_cost_centavos, v_order_id, auth.uid()
    );
  end loop;

  -- Lock finished-goods balances in deterministic order for batch-produced lines.
  for v_req in
    select ol.product_id, p.name, sum(ol.quantity) as required
    from public.order_lines ol
    join public.products p on p.id = ol.product_id
    where ol.order_id = v_order_id and ol.stock_model = 'batch_produced'
    group by ol.product_id, p.name
    order by ol.product_id
  loop
    select * into v_finished from public.finished_goods_balances
    where branch_id = p_branch_id and product_id = v_req.product_id
    for update;
    if not found or v_finished.quantity < v_req.required then
      raise exception 'Insufficient finished stock for %', v_req.name;
    end if;
  end loop;

  -- Snapshot costs and consumption rows for every line.
  for v_line in select * from public.order_lines where order_id = v_order_id loop
    v_line_cost := 0;
    v_estimated := false;

    if v_line.stock_model = 'made_to_order' then
      if not exists (select 1 from public.product_recipes where product_id = v_line.product_id) then
        v_estimated := true;
      end if;

      insert into public.order_line_consumptions (order_line_id, ingredient_id, quantity, unit_cost_centavos, source)
      select v_line.id, r.ingredient_id, r.quantity * v_line.quantity,
             coalesce(ib.average_cost_centavos, 0), 'recipe'
      from public.product_recipes r
      left join public.ingredient_balances ib
        on ib.branch_id = p_branch_id and ib.ingredient_id = r.ingredient_id
      where r.product_id = v_line.product_id;

      insert into public.order_line_consumptions (order_line_id, ingredient_id, quantity, unit_cost_centavos, source)
      select v_line.id, por.ingredient_id, por.quantity * v_line.quantity,
             coalesce(ib.average_cost_centavos, 0), 'option'
      from public.order_line_options olo
      join public.product_option_recipes por on por.option_id = olo.option_id
      left join public.ingredient_balances ib
        on ib.branch_id = p_branch_id and ib.ingredient_id = por.ingredient_id
      where olo.order_line_id = v_line.id;

      select coalesce(sum(round(quantity * unit_cost_centavos)), 0) into v_line_cost
      from public.order_line_consumptions where order_line_id = v_line.id;

      update public.order_line_options olo
      set unit_cost_centavos = coalesce((
        select sum(por.quantity * ib.average_cost_centavos)
        from public.product_option_recipes por
        left join public.ingredient_balances ib
          on ib.branch_id = p_branch_id and ib.ingredient_id = por.ingredient_id
        where por.option_id = olo.option_id
      ), 0)
      where olo.order_line_id = v_line.id;
    else
      select * into v_finished from public.finished_goods_balances
      where branch_id = p_branch_id and product_id = v_line.product_id;
      if not found then raise exception 'Insufficient finished stock for %', v_line.product_name; end if;
      v_line_cost := round(v_finished.average_cost_centavos * v_line.quantity);
      update public.finished_goods_balances
        set quantity = quantity - v_line.quantity, version = version + 1
        where branch_id = p_branch_id and product_id = v_line.product_id;
      insert into public.inventory_movements (
        branch_id, product_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
      ) values (
        p_branch_id, v_line.product_id, 'sale_consumption', -v_line.quantity,
        v_finished.average_cost_centavos, v_order_id, auth.uid()
      );
      insert into public.order_line_consumptions (order_line_id, product_id, quantity, unit_cost_centavos, source)
      values (v_line.id, v_line.product_id, v_line.quantity, v_finished.average_cost_centavos, 'finished_goods');
    end if;

    update public.order_lines
      set cost_snapshot_centavos = v_line_cost, cost_estimated = v_estimated
      where id = v_line.id;
  end loop;

  v_total := v_subtotal - v_discount;
  if v_settings.tax_inclusive_enabled and v_settings.tax_rate_bps > 0 then
    v_tax := round(v_total::numeric * v_settings.tax_rate_bps / (10000 + v_settings.tax_rate_bps))::integer;
  end if;

  if v_payment_kind = 'cash' then
    v_tendered := coalesce(p_tendered_centavos, v_total);
    if v_tendered < v_total then raise exception 'Cash received is less than the total'; end if;
    v_change := v_tendered - v_total;
  else
    v_tendered := null;
    v_change := null;
  end if;

  update public.orders set
    subtotal_centavos = v_subtotal,
    discount_centavos = v_discount,
    discount_reason = nullif(trim(p_discount_reason), ''),
    tax_centavos = v_tax,
    tax_rate_bps = v_settings.tax_rate_bps,
    tax_inclusive = v_settings.tax_inclusive_enabled,
    total_centavos = v_total,
    payment_method_id = p_payment_method_id,
    tendered_centavos = v_tendered,
    change_centavos = v_change,
    updated_at = now()
  where id = v_order_id;

  insert into public.payments (order_id, method, amount_centavos, reference, payment_method_id, tendered_centavos, change_centavos)
  values (v_order_id, v_payment_kind, v_total, nullif(trim(p_payment_reference), ''), p_payment_method_id, v_tendered, v_change);

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'checkout_completed', 'order', v_order_id,
    jsonb_build_object('total_centavos', v_total, 'captured_at', p_captured_at, 'device_id', p_device_id));

  return v_order_id;
end;
$$;

create or replace function public.sync_offline_checkout(
  p_branch_id uuid,
  p_device_id uuid,
  p_request_id uuid,
  p_payment_method_id uuid,
  p_payment_reference text,
  p_items jsonb,
  p_discount_centavos integer default 0,
  p_discount_reason text default null,
  p_tendered_centavos integer default null,
  p_captured_at timestamptz default now(),
  p_config_revision integer default null,
  p_local_sequence bigint default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_order_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_line public.order_lines%rowtype;
  v_option jsonb;
  v_option_row public.product_options%rowtype;
  v_qty integer;
  v_subtotal integer := 0;
  v_discount integer := coalesce(p_discount_centavos, 0);
  v_total integer;
  v_error text;
  v_payment_method public.payment_methods%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_device_id is null then raise exception 'An offline sale requires a registered device'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id
  where b.id = p_branch_id;
  if v_shop_id is null or not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  if not exists (
    select 1 from public.branch_devices d
    where d.id = p_device_id and d.branch_id = p_branch_id and d.user_id = auth.uid() and d.revoked_at is null
  ) then raise exception 'Device is not registered for this branch'; end if;

  select * into v_payment_method from public.payment_methods
  where id = p_payment_method_id and shop_id = v_shop_id and active;
  if not found then raise exception 'Payment method is unavailable'; end if;

  begin
    v_order_id := public.record_checkout(
      p_branch_id, p_device_id, p_request_id, p_payment_method_id, p_payment_reference,
      p_items, p_discount_centavos, p_discount_reason, p_tendered_centavos, p_captured_at, p_config_revision
    );
    insert into public.sync_requests (
      device_id, request_id, action_type, status, captured_at, sync_state, branch_id, user_id,
      local_sequence, config_revision, payload, server_result, updated_at
    ) values (
      p_device_id, p_request_id, 'checkout', 'completed', coalesce(p_captured_at, now()), 'synced',
      p_branch_id, auth.uid(), p_local_sequence, p_config_revision, jsonb_build_object('items', p_items),
      jsonb_build_object('order_id', v_order_id), now()
    )
    on conflict (device_id, request_id) do update set
      sync_state = 'synced', status = 'completed',
      server_result = jsonb_build_object('order_id', v_order_id), updated_at = now();
    return v_order_id;
  exception when others then
    v_error := sqlerrm;
  end;

  -- Preserve the queued sale for owner review. No stock is deducted and no revenue is recognized.
  insert into public.orders (
    branch_id, cashier_id, device_id, request_id, status, total_centavos,
    captured_at, created_at, offline_captured_at, review_reason, config_revision
  ) values (
    p_branch_id, auth.uid(), p_device_id, p_request_id, 'needs_review', 0,
    coalesce(p_captured_at, now()), now(), p_captured_at, v_error, p_config_revision
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := greatest(coalesce((v_item->>'quantity')::integer, 1), 1);
    select * into v_product from public.products
    where id = (v_item->>'product_id')::uuid and shop_id = v_shop_id;
    if found then
      insert into public.order_lines (
        order_id, product_id, product_name, unit_price_centavos, quantity,
        cost_snapshot_centavos, selected_options, line_subtotal_centavos, stock_model, cost_estimated
      ) values (
        v_order_id, v_product.id, v_product.name, v_product.price_centavos, v_qty,
        0, coalesce(v_item->'selected_options', '[]'::jsonb),
        v_product.price_centavos * v_qty, v_product.stock_model, true
      ) returning * into v_line;
      for v_option in select value from jsonb_array_elements(coalesce(v_item->'selected_options', '[]'::jsonb)) loop
        if (v_option->>'id') is not null then
          select * into v_option_row from public.product_options
          where id = (v_option->>'id')::uuid and product_id = v_product.id;
        else
          select * into v_option_row from public.product_options
          where product_id = v_product.id and name = (v_option->>'name');
        end if;
        if found then
          insert into public.order_line_options (order_line_id, option_id, option_name, unit_cost_centavos)
          values (v_line.id, v_option_row.id, v_option_row.name, 0);
        else
          insert into public.order_line_options (order_line_id, option_id, option_name, unit_cost_centavos)
          values (v_line.id, null, coalesce(v_option->>'name', 'Unknown option'), 0);
        end if;
      end loop;
      v_subtotal := v_subtotal + (v_product.price_centavos * v_qty);
    end if;
  end loop;

  if v_discount > v_subtotal then v_discount := v_subtotal; end if;
  v_total := v_subtotal - v_discount;
  update public.orders set subtotal_centavos = v_subtotal, discount_centavos = v_discount,
    discount_reason = nullif(trim(p_discount_reason), ''), total_centavos = v_total,
    payment_method_id = p_payment_method_id,
    tendered_centavos = case when v_payment_method.kind = 'cash'
      then coalesce(p_tendered_centavos, v_total) else null end,
    change_centavos = case when v_payment_method.kind = 'cash'
      then greatest(coalesce(p_tendered_centavos, v_total) - v_total, 0) else null end,
    updated_at = now()
  where id = v_order_id;

  insert into public.sync_requests (
    device_id, request_id, action_type, status, captured_at, sync_state, branch_id, user_id,
    local_sequence, config_revision, payload, error_code, error_detail, server_result, updated_at
  ) values (
    p_device_id, p_request_id, 'checkout', 'needs_review', coalesce(p_captured_at, now()), 'needs_review',
    p_branch_id, auth.uid(), p_local_sequence, p_config_revision, jsonb_build_object('items', p_items),
    'checkout_conflict', v_error, jsonb_build_object('order_id', v_order_id), now()
  )
  on conflict (device_id, request_id) do update set
    sync_state = 'needs_review', status = 'needs_review', error_code = 'checkout_conflict',
    error_detail = v_error, server_result = jsonb_build_object('order_id', v_order_id), updated_at = now();

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'offline_checkout_needs_review', 'order', v_order_id,
    jsonb_build_object('reason', v_error, 'captured_at', p_captured_at));

  return v_order_id;
end;
$$;

create or replace function public.record_restock(
  p_branch_id uuid,
  p_request_id uuid,
  p_supplier text,
  p_note text,
  p_items jsonb,
  p_delivery_fee_centavos integer default 0,
  p_paid_from_cash boolean default false,
  p_cash_movement_id uuid default null,
  p_shift_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_restock_id uuid;
  v_existing uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_item jsonb;
  v_ingredient public.ingredients%rowtype;
  v_balance public.ingredient_balances%rowtype;
  v_quantity numeric(14,3);
  v_unit_cost integer;
  v_total integer := 0;
  v_new_qty numeric(14,3);
  v_new_avg numeric(18,6);
  v_shift_id uuid;
  v_cash_movement_id uuid;
  v_deduction_amount integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'At least one restock item is required'; end if;
  if p_delivery_fee_centavos is null or p_delivery_fee_centavos < 0 then raise exception 'Delivery fee cannot be negative'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;
  if v_shop_id is null or not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select id into v_existing from public.restocks where branch_id = p_branch_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;

  insert into public.restocks (branch_id, request_id, supplier, note, delivery_fee_centavos, paid_from_cash, cash_movement_id, created_by)
  values (p_branch_id, p_request_id, nullif(trim(p_supplier), ''), nullif(trim(p_note), ''), coalesce(p_delivery_fee_centavos, 0), coalesce(p_paid_from_cash, false), p_cash_movement_id, auth.uid())
  returning id into v_restock_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_ingredient from public.ingredients
    where id = (v_item->>'ingredient_id')::uuid and shop_id = v_shop_id and active;
    if not found then raise exception 'Ingredient is unavailable'; end if;
    v_quantity := (v_item->>'quantity')::numeric(14,3);
    v_unit_cost := (v_item->>'unit_cost_centavos')::integer;
    if v_quantity is null or v_quantity <= 0 then raise exception 'Restock quantity must be positive'; end if;
    if v_unit_cost is null or v_unit_cost < 0 then raise exception 'Unit cost cannot be negative'; end if;

    insert into public.ingredient_balances (branch_id, ingredient_id, quantity, average_cost_centavos)
    values (p_branch_id, v_ingredient.id, 0, 0)
    on conflict (branch_id, ingredient_id) do nothing;

    select * into v_balance from public.ingredient_balances
    where branch_id = p_branch_id and ingredient_id = v_ingredient.id for update;

    v_new_qty := v_balance.quantity + v_quantity;
    v_new_avg := ((v_balance.quantity * v_balance.average_cost_centavos) + (v_quantity * v_unit_cost)) / v_new_qty;

    update public.ingredient_balances
      set quantity = v_new_qty, average_cost_centavos = v_new_avg, version = version + 1
      where branch_id = p_branch_id and ingredient_id = v_ingredient.id;

    insert into public.restock_items (restock_id, ingredient_id, quantity, unit_cost_centavos)
    values (v_restock_id, v_ingredient.id, v_quantity, v_unit_cost);

    insert into public.inventory_movements (
      branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
    ) values (p_branch_id, v_ingredient.id, 'restock', v_quantity, v_unit_cost, v_restock_id, auth.uid());

    v_total := v_total + round(v_quantity * v_unit_cost);
  end loop;

  if coalesce(p_paid_from_cash, false) then
    v_deduction_amount := v_total + coalesce(p_delivery_fee_centavos, 0);
    if v_deduction_amount <= 0 then raise exception 'Nothing to deduct'; end if;

    if p_shift_id is not null then
      v_shift_id := p_shift_id;
    else
      select id into v_shift_id from public.cash_shifts
      where branch_id = p_branch_id and closed_at is null
        and (cashier_id = auth.uid() or public.can_manage_branch(p_branch_id))
      limit 1;
    end if;

    if v_shift_id is null then raise exception 'No open shift found for this branch'; end if;

    select public.record_cash_payout(v_shift_id, v_deduction_amount, 'Restock: ' || coalesce(nullif(trim(p_supplier), ''), 'Restock'), p_request_id)
    into v_cash_movement_id;

    update public.restocks set cash_movement_id = v_cash_movement_id where id = v_restock_id;
  end if;

  update public.restocks set total_cost_centavos = v_total where id = v_restock_id;
  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'restock_posted', 'restock', v_restock_id,
    jsonb_build_object('total_cost_centavos', v_total, 'delivery_fee_centavos', coalesce(p_delivery_fee_centavos, 0), 'paid_from_cash', coalesce(p_paid_from_cash, false), 'cash_movement_id', v_cash_movement_id));
  return v_restock_id;
end;
$$;

create or replace function public.post_production_batch(
  p_branch_id uuid,
  p_product_id uuid,
  p_request_id uuid,
  p_actual_yield numeric,
  p_waste_quantity numeric default 0,
  p_waste_reason text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_batch_id uuid;
  v_existing uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_product public.products%rowtype;
  v_balance public.ingredient_balances%rowtype;
  v_finished public.finished_goods_balances%rowtype;
  v_recipe record;
  v_total_cost integer := 0;
  v_new_qty numeric(14,3);
  v_new_avg numeric(18,6);
  v_cost_per_unit numeric(18,6);
  v_expected numeric(14,3);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_actual_yield is null or p_actual_yield < 0 then raise exception 'Actual yield cannot be negative'; end if;

  select p.* into v_product from public.products p where p.id = p_product_id;
  if v_product.id is null then raise exception 'Product not found'; end if;
  select s.id, s.group_id into v_shop_id, v_group_id
  from public.shops s where s.id = v_product.shop_id;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  if not exists (select 1 from public.branches b where b.id = p_branch_id and b.shop_id = v_shop_id) then
    raise exception 'Product does not belong to this branch shop';
  end if;
  if v_product.stock_model <> 'batch_produced' then raise exception 'Product is not batch-produced'; end if;

  select id into v_existing from public.production_batches where branch_id = p_branch_id and request_id = p_request_id;
  if v_existing is not null then return v_existing; end if;

  v_expected := v_product.expected_yield_quantity;
  if not exists (select 1 from public.product_recipes where product_id = p_product_id) then
    raise exception 'A recipe is required before producing this product';
  end if;

  insert into public.production_batches (
    branch_id, product_id, request_id, expected_yield, actual_yield, waste_quantity,
    waste_reason, prepared_by, total_cost_centavos, cost_per_unit_centavos
  ) values (
    p_branch_id, p_product_id, p_request_id, v_expected, p_actual_yield, greatest(p_waste_quantity, 0),
    nullif(trim(p_waste_reason), ''), auth.uid(), 0, 0
  ) returning id into v_batch_id;

  for v_recipe in
    select r.ingredient_id, r.quantity, i.name
    from public.product_recipes r join public.ingredients i on i.id = r.ingredient_id
    where r.product_id = p_product_id order by r.ingredient_id
  loop
    select * into v_balance from public.ingredient_balances
    where branch_id = p_branch_id and ingredient_id = v_recipe.ingredient_id for update;
    if not found or v_balance.quantity < v_recipe.quantity then
      raise exception 'Insufficient ingredient stock for %', v_recipe.name;
    end if;
  end loop;

  for v_recipe in
    select r.ingredient_id, r.quantity, i.name
    from public.product_recipes r join public.ingredients i on i.id = r.ingredient_id
    where r.product_id = p_product_id order by r.ingredient_id
  loop
    select * into v_balance from public.ingredient_balances
    where branch_id = p_branch_id and ingredient_id = v_recipe.ingredient_id;
    update public.ingredient_balances
      set quantity = quantity - v_recipe.quantity, version = version + 1
      where branch_id = p_branch_id and ingredient_id = v_recipe.ingredient_id;
    insert into public.production_batch_inputs (batch_id, ingredient_id, quantity, unit_cost_centavos)
    values (v_batch_id, v_recipe.ingredient_id, v_recipe.quantity, v_balance.average_cost_centavos);
    insert into public.inventory_movements (
      branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
    ) values (
      p_branch_id, v_recipe.ingredient_id, 'production_consumption', -v_recipe.quantity,
      v_balance.average_cost_centavos, v_batch_id, auth.uid()
    );
    v_total_cost := v_total_cost + round(v_recipe.quantity * v_balance.average_cost_centavos);
  end loop;

  insert into public.finished_goods_balances (branch_id, product_id, quantity, average_cost_centavos)
  values (p_branch_id, p_product_id, 0, 0)
  on conflict (branch_id, product_id) do nothing;
  select * into v_finished from public.finished_goods_balances
  where branch_id = p_branch_id and product_id = p_product_id for update;

  if p_actual_yield > 0 then
    v_new_qty := v_finished.quantity + p_actual_yield;
    v_new_avg := ((v_finished.quantity * v_finished.average_cost_centavos) + v_total_cost) / v_new_qty;
    v_cost_per_unit := v_total_cost / p_actual_yield;
    update public.finished_goods_balances
      set quantity = v_new_qty, average_cost_centavos = v_new_avg, version = version + 1
      where branch_id = p_branch_id and product_id = p_product_id;
    insert into public.inventory_movements (
      branch_id, product_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
    ) values (
      p_branch_id, p_product_id, 'production_output', p_actual_yield,
      v_new_avg, v_batch_id, auth.uid()
    );
  else
    v_cost_per_unit := 0;
  end if;

  update public.production_batches set
    total_cost_centavos = v_total_cost,
    cost_per_unit_centavos = v_cost_per_unit,
    waste_quantity = greatest(coalesce(p_waste_quantity, v_expected - p_actual_yield), 0)
  where id = v_batch_id;

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'production_batch_posted', 'production_batch', v_batch_id,
    jsonb_build_object('actual_yield', p_actual_yield, 'total_cost_centavos', v_total_cost));
  return v_batch_id;
end;
$$;

revoke all on function public.can_access_shop(uuid) from public;
revoke all on function public.can_manage_shop(uuid) from public;
revoke all on function public.can_manage_branch(uuid) from public;
revoke all on function public.bump_shop_config(uuid) from public;
revoke all on function public.record_checkout(uuid, uuid, uuid, uuid, text, jsonb, integer, text, integer, timestamptz, integer) from public;
revoke all on function public.sync_offline_checkout(uuid, uuid, uuid, uuid, text, jsonb, integer, text, integer, timestamptz, integer, bigint) from public;
revoke all on function public.record_restock(uuid, uuid, text, text, jsonb) from public;
revoke all on function public.post_production_batch(uuid, uuid, uuid, numeric, numeric, text) from public;

grant execute on function public.record_checkout(uuid, uuid, uuid, uuid, text, jsonb, integer, text, integer, timestamptz, integer) to authenticated;
grant execute on function public.sync_offline_checkout(uuid, uuid, uuid, uuid, text, jsonb, integer, text, integer, timestamptz, integer, bigint) to authenticated;
grant execute on function public.record_restock(uuid, uuid, text, text, jsonb) to authenticated;
grant execute on function public.post_production_batch(uuid, uuid, uuid, numeric, numeric, text) to authenticated;
