-- All monetary values sent to this RPC are integer centavos. The server reads product prices and costs.
create or replace function public.record_checkout(
  p_branch_id uuid,
  p_device_id uuid,
  p_request_id uuid,
  p_payment_method public.payment_kind,
  p_payment_reference text,
  p_items jsonb,
  p_captured_at timestamptz default now()
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_order_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_total integer := 0;
  v_cost integer;
  v_recipe record;
  v_balance public.ingredient_balances%rowtype;
  v_finished public.finished_goods_balances%rowtype;
  v_option_count integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'An order needs at least one item'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;
  if not found or not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  if p_device_id is not null and not exists (
    select 1 from public.branch_devices d
    where d.id = p_device_id and d.branch_id = p_branch_id and d.user_id = auth.uid() and d.revoked_at is null
  ) then raise exception 'Device is not registered for this branch'; end if;

  if p_device_id is not null then
    select id into v_order_id from public.orders where device_id = p_device_id and request_id = p_request_id;
    if found then return v_order_id; end if;
  end if;

  insert into public.orders(branch_id, cashier_id, device_id, request_id, status, total_centavos, captured_at)
  values (p_branch_id, auth.uid(), p_device_id, p_request_id, 'completed', 0, p_captured_at)
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < 1 then raise exception 'Invalid item quantity'; end if;

    select * into v_product from public.products
    where id = (v_item->>'product_id')::uuid and shop_id = v_shop_id and active;
    if not found then raise exception 'Product is unavailable'; end if;

    select count(*) into v_option_count from jsonb_array_elements(coalesce(v_item->'selected_options', '[]'::jsonb));
    if v_option_count <> v_product.flavor_choices then raise exception 'Incorrect number of selected options for %', v_product.name; end if;

    v_cost := 0;
    if v_product.stock_model = 'made_to_order' then
      for v_recipe in select * from public.product_recipes where product_id = v_product.id loop
        select * into v_balance from public.ingredient_balances
        where branch_id = p_branch_id and ingredient_id = v_recipe.ingredient_id for update;
        if not found or v_balance.quantity < v_recipe.quantity * v_qty then raise exception 'Insufficient ingredient stock for %', v_product.name; end if;
        v_cost := v_cost + round(v_balance.average_cost_centavos * v_recipe.quantity * v_qty)::integer;
        update public.ingredient_balances set quantity = quantity - v_recipe.quantity * v_qty, version = version + 1
        where branch_id = p_branch_id and ingredient_id = v_recipe.ingredient_id;
        insert into public.inventory_movements(branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by)
        values (p_branch_id, v_recipe.ingredient_id, 'sale_consumption', -v_recipe.quantity * v_qty, v_balance.average_cost_centavos, v_order_id, auth.uid());
      end loop;
    else
      select * into v_finished from public.finished_goods_balances
      where branch_id = p_branch_id and product_id = v_product.id for update;
      if not found or v_finished.quantity < v_qty then raise exception 'Insufficient finished stock for %', v_product.name; end if;
      v_cost := round(v_finished.average_cost_centavos * v_qty)::integer;
      update public.finished_goods_balances set quantity = quantity - v_qty, version = version + 1
      where branch_id = p_branch_id and product_id = v_product.id;
      insert into public.inventory_movements(branch_id, product_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by)
      values (p_branch_id, v_product.id, 'sale_consumption', -v_qty, v_finished.average_cost_centavos, v_order_id, auth.uid());
    end if;

    insert into public.order_lines(order_id, product_id, product_name, unit_price_centavos, quantity, cost_snapshot_centavos, selected_options)
    values (v_order_id, v_product.id, v_product.name, v_product.price_centavos, v_qty, v_cost, coalesce(v_item->'selected_options', '[]'::jsonb));
    v_total := v_total + v_product.price_centavos * v_qty;
  end loop;

  update public.orders set total_centavos = v_total where id = v_order_id;
  insert into public.payments(order_id, method, amount_centavos, reference)
  values (v_order_id, p_payment_method, v_total, nullif(trim(p_payment_reference), ''));
  insert into public.audit_events(group_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, auth.uid(), 'checkout_completed', 'order', v_order_id, jsonb_build_object('captured_at', p_captured_at));
  return v_order_id;
exception when others then
  raise;
end;
$$;

revoke all on function public.record_checkout(uuid, uuid, uuid, public.payment_kind, text, jsonb, timestamptz) from public;
grant execute on function public.record_checkout(uuid, uuid, uuid, public.payment_kind, text, jsonb, timestamptz) to authenticated;
