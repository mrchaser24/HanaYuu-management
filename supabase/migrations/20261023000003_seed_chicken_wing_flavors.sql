-- Preserve the supplied chicken-wings pricing and add persistent default flavors.
-- This is additive and safe to run repeatedly: it fills only products that have no options yet.
create or replace function public.ensure_chicken_wing_catalog(target_shop uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_product_id uuid;
  v_default_flavor text;
  v_default_flavors constant text[] := array[
    'Buffalo',
    'Garlic Parmesan',
    'Honey Soy',
    'Korean BBQ',
    'Salted Egg',
    'Spicy Yangnyeom'
  ];
begin
  select group_id into v_group_id
  from public.shops
  where id = target_shop;

  if v_group_id is null
    or not public.is_group_member(
      v_group_id,
      array['super_admin', 'owner']::public.business_role[]
    ) then
    raise exception 'Shop configuration access denied';
  end if;

  -- Preserve the supplied price and required flavor count for each menu item.
  insert into public.products (shop_id, name, description, price_centavos, flavor_choices, stock_model)
  values
    (target_shop, 'Solo 2-piece meal', '2 wings + 1 Java rice', 8900, 1, 'made_to_order'),
    (target_shop, 'Solo 3-piece meal', '3 wings + 1 Java rice', 11900, 1, 'made_to_order'),
    (target_shop, '6-piece wings', '6 wingette/drummette', 18900, 2, 'made_to_order'),
    (target_shop, '12-piece wings', '12 wingette/drummette', 34900, 3, 'made_to_order'),
    (target_shop, '20-piece wings', '20 wingette/drummette', 54900, 4, 'made_to_order'),
    (target_shop, '30-piece wings', '30 wingette/drummette', 79900, 5, 'made_to_order')
  on conflict (shop_id, name) do nothing;

  -- Do not overwrite owner-managed flavors. Only initialize a product with no options.
  for v_product_id in
    select id
    from public.products
    where shop_id = target_shop
      and name in (
        'Solo 2-piece meal',
        'Solo 3-piece meal',
        '6-piece wings',
        '12-piece wings',
        '20-piece wings',
        '30-piece wings'
      )
      and not exists (
        select 1
        from public.product_options option_row
        where option_row.product_id = public.products.id
      )
  loop
    foreach v_default_flavor in array v_default_flavors
    loop
      insert into public.product_options (product_id, name, active)
      values (v_product_id, v_default_flavor, true)
      on conflict (product_id, name) do nothing;
    end loop;
  end loop;
end;
$$;

revoke all on function public.ensure_chicken_wing_catalog(uuid) from public;
grant execute on function public.ensure_chicken_wing_catalog(uuid) to authenticated;

comment on function public.ensure_chicken_wing_catalog(uuid) is
  'Idempotently creates the supplied chicken-wings menu and default flavors only when a product has no owner-managed options.';
