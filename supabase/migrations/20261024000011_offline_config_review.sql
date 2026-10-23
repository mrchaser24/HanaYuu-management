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
  v_existing uuid;
  v_order_status public.order_status;
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

  select o.id, o.status into v_existing, v_order_status
  from public.orders o
  where o.branch_id = p_branch_id and o.request_id = p_request_id;
  if v_existing is not null then
    if v_order_status <> 'completed' then
      return null;
    end if;
    insert into public.sync_requests (
      device_id, request_id, action_type, status, captured_at, sync_state, branch_id, user_id,
      local_sequence, config_revision, payload, server_result, updated_at
    ) values (
      p_device_id, p_request_id, 'checkout', 'completed', coalesce(p_captured_at, now()), 'synced',
      p_branch_id, auth.uid(), p_local_sequence, p_config_revision, jsonb_build_object('items', p_items),
      jsonb_build_object('order_id', v_existing), now()
    )
    on conflict (device_id, request_id) do update set
      sync_state = 'synced', status = 'completed',
      server_result = jsonb_build_object('order_id', v_existing), updated_at = now();
    return v_existing;
  end if;

  begin
    if p_config_revision is not null and p_config_revision <> (
      select s.config_revision from public.shops s where s.id = v_shop_id
    ) then
      raise exception 'Prices or products changed while this sale was offline';
    end if;
    v_order_id := public.record_checkout(
      p_branch_id, p_device_id, p_request_id, p_payment_method_id, p_payment_reference,
      p_items, p_discount_centavos, p_discount_reason, p_tendered_centavos, p_captured_at, p_config_revision
    );
    select o.status into v_order_status from public.orders o where o.id = v_order_id;
    if v_order_status <> 'completed' then
      return null;
    end if;
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

  return null;
end;
$$;
