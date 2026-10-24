-- Add kg and L (liter) as allowed ingredient base units.

-- 1. Relax the check constraint on the ingredients table.
alter table public.ingredients drop constraint if exists ingredients_base_unit_check;
alter table public.ingredients add constraint ingredients_base_unit_check
  check (base_unit in ('g', 'kg', 'ml', 'L', 'piece'));

-- 2. Update the upsert_ingredient RPC validation.
create or replace function public.upsert_ingredient(
  p_shop_id uuid,
  p_ingredient_id uuid default null,
  p_name text default null,
  p_base_unit text default 'g',
  p_low_stock_quantity numeric default 0,
  p_category text default '',
  p_active boolean default true,
  p_version integer default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_current integer;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_shop(p_shop_id) then raise exception 'Ingredient configuration access denied'; end if;
  if p_base_unit not in ('g', 'kg', 'ml', 'L', 'piece') then raise exception 'Invalid base unit'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 then raise exception 'An ingredient name is required'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;
  if p_ingredient_id is null then
    insert into public.ingredients (shop_id, name, base_unit, low_stock_quantity, category, active)
    values (p_shop_id, trim(p_name), p_base_unit, coalesce(p_low_stock_quantity, 0), coalesce(p_category, 'other'), coalesce(p_active, true))
    returning id into v_id;
  else
    select version into v_current from public.ingredients where id = p_ingredient_id and shop_id = p_shop_id;
    if v_current is null then raise exception 'Ingredient not found'; end if;
    if p_version is not null and p_version <> v_current then raise exception 'Ingredient changed; refresh and review'; end if;
    update public.ingredients set name = trim(p_name), base_unit = p_base_unit,
      low_stock_quantity = coalesce(p_low_stock_quantity, low_stock_quantity),
      category = coalesce(p_category, category), active = coalesce(p_active, active), version = version + 1
    where id = p_ingredient_id and shop_id = p_shop_id;
    v_id := p_ingredient_id;
  end if;
  perform public.bump_shop_config(p_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'ingredient_saved', 'ingredient', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

revoke all on function public.upsert_ingredient(uuid, uuid, text, text, numeric, text, boolean, integer) from public;
grant execute on function public.upsert_ingredient(uuid, uuid, text, text, numeric, text, boolean, integer) to authenticated;
