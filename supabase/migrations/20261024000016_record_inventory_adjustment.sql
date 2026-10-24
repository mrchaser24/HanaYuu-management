-- Manual inventory adjustment: set an ingredient's on-hand quantity to an
-- actual counted value, recording the difference as an 'adjustment' movement.
create or replace function public.record_inventory_adjustment(
  p_branch_id uuid,
  p_ingredient_id uuid,
  p_actual_quantity numeric,
  p_reason text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_balance public.ingredient_balances%rowtype;
  v_ingredient public.ingredients%rowtype;
  v_shop_id uuid;
  v_group_id uuid;
  v_delta numeric;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_actual_quantity is null or p_actual_quantity < 0 then raise exception 'Actual quantity cannot be negative'; end if;
  if p_reason is null or char_length(trim(p_reason)) < 3 then raise exception 'A reason is required (min 3 characters)'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;
  if v_shop_id is null then raise exception 'Branch not found'; end if;

  select * into v_ingredient from public.ingredients where id = p_ingredient_id;
  if not found then raise exception 'Ingredient not found'; end if;

  -- Ensure a balance row exists for this branch/ingredient.
  insert into public.ingredient_balances (branch_id, ingredient_id, quantity, average_cost_centavos)
  values (p_branch_id, p_ingredient_id, 0, 0)
  on conflict (branch_id, ingredient_id) do nothing;

  select * into v_balance from public.ingredient_balances
  where branch_id = p_branch_id and ingredient_id = p_ingredient_id for update;

  v_delta := p_actual_quantity - v_balance.quantity;
  if v_delta = 0 then
    return p_ingredient_id;
  end if;

  update public.ingredient_balances
  set quantity = p_actual_quantity, version = version + 1
  where branch_id = p_branch_id and ingredient_id = p_ingredient_id;

  insert into public.inventory_movements (
    branch_id, ingredient_id, kind, quantity_delta, unit_cost_centavos, reference_id, created_by
  ) values (
    p_branch_id, p_ingredient_id, 'adjustment', v_delta,
    v_balance.average_cost_centavos, null, auth.uid()
  );

  insert into public.audit_events (group_id, branch_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, v_shop_id, auth.uid(), 'inventory_adjustment', 'ingredient_balance', p_ingredient_id,
    jsonb_build_object('actual_quantity', p_actual_quantity, 'previous_quantity', v_balance.quantity, 'delta', v_delta, 'reason', p_reason));

  return p_ingredient_id;
end;
$$;

revoke all on function public.record_inventory_adjustment(uuid, uuid, numeric, text) from public;
grant execute on function public.record_inventory_adjustment(uuid, uuid, numeric, text) to authenticated;
