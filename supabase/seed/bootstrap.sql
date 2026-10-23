-- One-time bootstrap for the first business group, shop, branch, and super admin.
-- 1) Create the owner account in Supabase Auth first.
-- 2) Replace owner@example.com below with that account's email.
-- 3) Run this file in the Supabase SQL editor after all migrations.
-- The script is safe to re-run; it does not overwrite existing owner edits.

do $$
declare
  v_email text := 'owner@example.com';
  v_user_id uuid;
  v_group_id uuid;
  v_shop_id uuid;
  v_branch_id uuid;
  v_display_name text;
  v_product record;
  v_default_flavors constant text[] := array[
    'Buffalo', 'Garlic Parmesan', 'Honey Soy',
    'Korean BBQ', 'Salted Egg', 'Spicy Yangnyeom'
  ];
begin
  select u.id,
         coalesce(
           nullif(trim(u.raw_user_meta_data->>'display_name'), ''),
           nullif(trim(u.raw_user_meta_data->>'name'), ''),
           nullif(split_part(u.email, '@', 1), ''),
           'Owner'
         )
    into v_user_id, v_display_name
  from auth.users u
  where lower(u.email) = lower(trim(v_email))
  limit 1;

  if v_user_id is null then
    raise exception 'No Auth user found for %. Create the account first, then edit and re-run this script.', v_email;
  end if;
  if char_length(v_display_name) < 2 then v_display_name := 'Owner'; end if;

  insert into public.profiles (id, display_name)
  values (v_user_id, left(v_display_name, 100))
  on conflict (id) do nothing;

  select id into v_group_id from public.business_groups where name = 'Benta Business Control' limit 1;
  if v_group_id is null then
    insert into public.business_groups (name) values ('Benta Business Control') returning id into v_group_id;
  end if;

  select id into v_shop_id from public.shops where group_id = v_group_id and name = 'Benta Chicken Wings' limit 1;
  if v_shop_id is null then
    insert into public.shops (group_id, name)
    values (v_group_id, 'Benta Chicken Wings') returning id into v_shop_id;
  end if;

  select id into v_branch_id from public.branches where shop_id = v_shop_id and name = 'Main Branch' limit 1;
  if v_branch_id is null then
    insert into public.branches (shop_id, name)
    values (v_shop_id, 'Main Branch') returning id into v_branch_id;
  end if;

  if not exists (
    select 1 from public.memberships
    where user_id = v_user_id and group_id = v_group_id and role = 'super_admin'
  ) then
    insert into public.memberships (user_id, group_id, role)
    values (v_user_id, v_group_id, 'super_admin');
  end if;

  insert into public.shop_settings (shop_id) values (v_shop_id)
  on conflict (shop_id) do nothing;

  insert into public.payment_methods (shop_id, code, name, kind, requires_reference, active, sort_order)
  values
    (v_shop_id, 'cash', 'Cash', 'cash', false, true, 1),
    (v_shop_id, 'gcash', 'GCash', 'gcash', true, true, 2)
  on conflict (shop_id, code) do update set
    name = excluded.name, kind = excluded.kind,
    requires_reference = excluded.requires_reference,
    active = excluded.active, sort_order = excluded.sort_order;

  insert into public.products (shop_id, name, description, price_centavos, flavor_choices, stock_model)
  values
    (v_shop_id, 'Solo 2-piece meal', '2 wings + 1 Java rice', 8900, 1, 'made_to_order'),
    (v_shop_id, 'Solo 3-piece meal', '3 wings + 1 Java rice', 11900, 1, 'made_to_order'),
    (v_shop_id, '6-piece wings', '6 wingette/drummette', 18900, 2, 'made_to_order'),
    (v_shop_id, '12-piece wings', '12 wingette/drummette', 34900, 3, 'made_to_order'),
    (v_shop_id, '20-piece wings', '20 wingette/drummette', 54900, 4, 'made_to_order'),
    (v_shop_id, '30-piece wings', '30 wingette/drummette', 79900, 5, 'made_to_order')
  on conflict (shop_id, name) do nothing;

  for v_product in
    select id from public.products
    where shop_id = v_shop_id
      and name in (
        'Solo 2-piece meal', 'Solo 3-piece meal', '6-piece wings',
        '12-piece wings', '20-piece wings', '30-piece wings'
      )
      and not exists (select 1 from public.product_options o where o.product_id = products.id)
  loop
    insert into public.product_options (product_id, name, active)
    select v_product.id, flavor, true
    from unnest(v_default_flavors) as flavor
    on conflict (product_id, name) do nothing;
  end loop;

  raise notice 'Bootstrap complete. Group %, shop %, branch %, super admin %.',
    v_group_id, v_shop_id, v_branch_id, v_email;
end $$;
