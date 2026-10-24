-- ============================================================
-- Global shop-level flavors
-- Replaces per-product product_options with shared shop_flavors
-- ============================================================

-- 1. New tables
create table if not exists public.shop_flavors (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  name text not null check (char_length(trim(name)) >= 1),
  active boolean not null default true,
  sort_order integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  unique (shop_id, name)
);

create table if not exists public.product_flavor_links (
  product_id uuid not null references public.products(id) on delete cascade,
  flavor_id uuid not null references public.shop_flavors(id) on delete cascade,
  primary key (product_id, flavor_id)
);

create table if not exists public.shop_flavor_recipes (
  id uuid primary key default gen_random_uuid(),
  flavor_id uuid not null references public.shop_flavors(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unique (flavor_id, ingredient_id)
);

create index if not exists shop_flavors_shop_active_idx on public.shop_flavors(shop_id, active);
create index if not exists product_flavor_links_product_idx on public.product_flavor_links(product_id);
create index if not exists product_flavor_links_flavor_idx on public.product_flavor_links(flavor_id);

-- 2. RLS
alter table public.shop_flavors enable row level security;
alter table public.product_flavor_links enable row level security;
alter table public.shop_flavor_recipes enable row level security;

create policy "members see shop flavors" on public.shop_flavors
  for select using (public.is_group_member((select group_id from public.shops where id = shop_id)));
create policy "members see flavor links" on public.product_flavor_links
  for select using (public.is_group_member((select s.group_id from public.products p join public.shops s on s.id = p.shop_id where p.id = product_id)));
create policy "members see flavor recipes" on public.shop_flavor_recipes
  for select using (public.is_group_member((select s.group_id from public.shop_flavors f join public.shops s on s.id = f.shop_id where f.id = flavor_id)));

grant select on public.shop_flavors, public.product_flavor_links, public.shop_flavor_recipes to authenticated;

-- 3. Migrate existing product_options → shop_flavors
-- Deduplicate by name per shop, then link to all products that had them
do $$
declare
  v_shop record;
  v_option_name text;
  v_flavor_id uuid;
  v_product_id uuid;
begin
  for v_shop in select id from public.shops loop
    -- Create unique shop_flavors from all product_options in this shop
    for v_option_name in
      select distinct po.name
      from public.product_options po
      join public.products p on p.id = po.product_id
      where p.shop_id = v_shop.id
      order by po.name
    loop
      insert into public.shop_flavors (shop_id, name, active, sort_order)
      values (v_shop.id, v_option_name, true,
        (select coalesce(min(po.sort_order), 0)
         from public.product_options po
         join public.products p on p.id = po.product_id
         where p.shop_id = v_shop.id and po.name = v_option_name))
      on conflict (shop_id, name) do nothing
      returning id into v_flavor_id;

      -- If the flavor already existed, fetch its id
      if v_flavor_id is null then
        select id into v_flavor_id from public.shop_flavors
        where shop_id = v_shop.id and name = v_option_name;
      end if;

      -- Link every product that had this option name
      for v_product_id in
        select distinct po.product_id
        from public.product_options po
        join public.products p on p.id = po.product_id
        where p.shop_id = v_shop.id and po.name = v_option_name
      loop
        insert into public.product_flavor_links (product_id, flavor_id)
        values (v_product_id, v_flavor_id)
        on conflict do nothing;
      end loop;

      -- Migrate option recipes to shop_flavor_recipes
      -- Take the first set found (they should all be the same for same-name options)
      insert into public.shop_flavor_recipes (flavor_id, ingredient_id, quantity)
      select v_flavor_id, por.ingredient_id, por.quantity
      from public.product_option_recipes por
      join public.product_options po on po.id = por.option_id
      join public.products p on p.id = po.product_id
      where p.shop_id = v_shop.id and po.name = v_option_name
      limit 10  -- safety limit
      on conflict (flavor_id, ingredient_id) do nothing;
    end loop;
  end loop;
end $$;

-- 4. Admin RPCs

-- Create or update a shop flavor
create or replace function public.upsert_shop_flavor(
  p_shop_id uuid,
  p_flavor_id uuid default null,
  p_name text default null,
  p_active boolean default true,
  p_sort_order integer default 0,
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
  if not public.can_manage_shop(p_shop_id) then raise exception 'Flavor configuration access denied'; end if;
  if p_name is null or char_length(trim(p_name)) < 1 then raise exception 'A flavor name is required'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;

  if p_flavor_id is null then
    insert into public.shop_flavors (shop_id, name, active, sort_order)
    values (p_shop_id, trim(p_name), coalesce(p_active, true), coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    select version into v_current from public.shop_flavors where id = p_flavor_id and shop_id = p_shop_id;
    if v_current is null then raise exception 'Flavor not found'; end if;
    if p_version is not null and p_version <> v_current then raise exception 'Flavor changed; refresh and review'; end if;
    update public.shop_flavors set
      name = trim(p_name), active = coalesce(p_active, active),
      sort_order = coalesce(p_sort_order, sort_order), version = version + 1
    where id = p_flavor_id and shop_id = p_shop_id;
    v_id := p_flavor_id;
  end if;

  perform public.bump_shop_config(p_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'flavor_saved', 'shop_flavor', v_id, jsonb_build_object('name', trim(p_name)));
  return v_id;
end;
$$;

-- Link/unlink a flavor to a product
create or replace function public.set_product_flavor_link(
  p_product_id uuid,
  p_flavor_id uuid,
  p_linked boolean
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select p.shop_id, s.group_id into v_shop_id, v_group_id
  from public.products p join public.shops s on s.id = p.shop_id where p.id = p_product_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Product access denied'; end if;

  if not exists (select 1 from public.shop_flavors where id = p_flavor_id and shop_id = v_shop_id) then
    raise exception 'Flavor does not belong to this shop';
  end if;

  if p_linked then
    insert into public.product_flavor_links (product_id, flavor_id) values (p_product_id, p_flavor_id) on conflict do nothing;
  else
    delete from public.product_flavor_links where product_id = p_product_id and flavor_id = p_flavor_id;
  end if;

  perform public.bump_shop_config(v_shop_id);
end;
$$;

-- Upsert shop flavor recipe (ingredient cost per flavor)
create or replace function public.upsert_shop_flavor_recipe(
  p_flavor_id uuid,
  p_ingredient_id uuid,
  p_quantity numeric
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select f.shop_id, s.group_id into v_shop_id, v_group_id
  from public.shop_flavors f join public.shops s on s.id = f.shop_id where f.id = p_flavor_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Flavor recipe access denied'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Quantity must be positive'; end if;

  insert into public.shop_flavor_recipes (flavor_id, ingredient_id, quantity)
  values (p_flavor_id, p_ingredient_id, p_quantity)
  on conflict (flavor_id, ingredient_id) do update set quantity = excluded.quantity
  returning id into v_id;

  perform public.bump_shop_config(v_shop_id);
  return v_id;
end;
$$;

-- Delete a shop flavor recipe line
create or replace function public.delete_shop_flavor_recipe(
  p_flavor_id uuid,
  p_ingredient_id uuid
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_shop_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select f.shop_id into v_shop_id from public.shop_flavors f where f.id = p_flavor_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Flavor recipe access denied'; end if;
  delete from public.shop_flavor_recipes where flavor_id = p_flavor_id and ingredient_id = p_ingredient_id;
  perform public.bump_shop_config(v_shop_id);
end;
$$;

-- Grant execute
revoke all on function public.upsert_shop_flavor(uuid, uuid, text, boolean, integer, integer) from public;
revoke all on function public.set_product_flavor_link(uuid, uuid, boolean) from public;
revoke all on function public.upsert_shop_flavor_recipe(uuid, uuid, numeric) from public;
revoke all on function public.delete_shop_flavor_recipe(uuid, uuid) from public;
grant execute on function public.upsert_shop_flavor(uuid, uuid, text, boolean, integer, integer) to authenticated;
grant execute on function public.set_product_flavor_link(uuid, uuid, boolean) to authenticated;
grant execute on function public.upsert_shop_flavor_recipe(uuid, uuid, numeric) to authenticated;
grant execute on function public.delete_shop_flavor_recipe(uuid, uuid) to authenticated;

-- 5. Update get_branch_catalog to load options from shop_flavors
--    The catalog still returns options[] per product for POS compatibility,
--    but now reads from shop_flavors + product_flavor_links
create or replace function public.get_branch_catalog(p_branch_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;

  select jsonb_build_object(
    'branch', (select to_jsonb(b) from public.branches b where b.id = p_branch_id),
    'shop', (select to_jsonb(s) from public.shops s where s.id = v_shop_id),
    'settings', coalesce(
      (select to_jsonb(ss) from public.shop_settings ss where ss.shop_id = v_shop_id),
      jsonb_build_object('shop_id', v_shop_id, 'tax_inclusive_enabled', false, 'tax_rate_bps', 1200, 'receipt_footer', '', 'version', 1)
    ),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm where pm.shop_id = v_shop_id and pm.active
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'description', coalesce(p.description, ''),
        'price_centavos', p.price_centavos,
        'flavor_choices', p.flavor_choices,
        'stock_model', p.stock_model,
        'active', p.active,
        'expected_yield_quantity', coalesce(p.expected_yield_quantity, 1),
        'expected_yield_unit', coalesce(p.expected_yield_unit, 'serving'),
        'pieces', p.pieces,
        'rice_included', coalesce(p.rice_included, false),
        'branch_available', coalesce(bps.available, true),
        'available', p.active and coalesce(bps.available, true),
        'recipe_complete', exists(select 1 from public.product_recipes r where r.product_id = p.id),
        'stock_quantity', case
          when p.stock_model = 'batch_produced' then (select fg.quantity from public.finished_goods_balances fg where fg.branch_id = p_branch_id and fg.product_id = p.id)
          else null end,
        'stock_available', case
          when p.stock_model = 'batch_produced' then coalesce((select fg.quantity from public.finished_goods_balances fg where fg.branch_id = p_branch_id and fg.product_id = p.id), 0) > 0
          when p.flavor_choices = 0 and not exists(select 1 from public.product_recipes r where r.product_id = p.id) then true
          else not exists(
            select 1 from public.product_recipes r
            left join public.ingredient_balances ib on ib.branch_id = p_branch_id and ib.ingredient_id = r.ingredient_id
            where r.product_id = p.id and coalesce(ib.quantity, 0) < r.quantity
          ) end,
        'options', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', sf.id, 'name', sf.name, 'sort_order', sf.sort_order,
            'cost_centavos', coalesce((
              select round(sum(sfr.quantity * coalesce(ib.average_cost_centavos, 0)))
              from public.shop_flavor_recipes sfr
              left join public.ingredient_balances ib
                on ib.branch_id = p_branch_id and ib.ingredient_id = sfr.ingredient_id
              where sfr.flavor_id = sf.id
            ), 0)
          ) order by sf.sort_order, sf.name)
          from public.shop_flavors sf
          join public.product_flavor_links pfl on pfl.flavor_id = sf.id and pfl.product_id = p.id
          where sf.shop_id = v_shop_id and sf.active
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p
      left join public.branch_product_settings bps
        on bps.branch_id = p_branch_id and bps.product_id = p.id
      where p.shop_id = v_shop_id and p.active
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- 6. Update record_checkout to validate against shop_flavors + links
--    The checkout already receives selected_options as [{id, name}]
--    We just change the lookup from product_options to shop_flavors + link check
create or replace function public.get_branch_catalog(p_branch_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
  v_result jsonb;
begin
  -- Already defined above, this is intentionally the same function
  -- (Postgres replaces it)
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select s.id, s.group_id into v_shop_id, v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;

  select jsonb_build_object(
    'branch', (select to_jsonb(b) from public.branches b where b.id = p_branch_id),
    'shop', (select to_jsonb(s) from public.shops s where s.id = v_shop_id),
    'settings', coalesce(
      (select to_jsonb(ss) from public.shop_settings ss where ss.shop_id = v_shop_id),
      jsonb_build_object('shop_id', v_shop_id, 'tax_inclusive_enabled', false, 'tax_rate_bps', 1200, 'receipt_footer', '', 'version', 1)
    ),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm where pm.shop_id = v_shop_id and pm.active
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'description', coalesce(p.description, ''),
        'price_centavos', p.price_centavos,
        'flavor_choices', p.flavor_choices,
        'stock_model', p.stock_model,
        'active', p.active,
        'expected_yield_quantity', coalesce(p.expected_yield_quantity, 1),
        'expected_yield_unit', coalesce(p.expected_yield_unit, 'serving'),
        'pieces', p.pieces,
        'rice_included', coalesce(p.rice_included, false),
        'branch_available', coalesce(bps.available, true),
        'available', p.active and coalesce(bps.available, true),
        'recipe_complete', exists(select 1 from public.product_recipes r where r.product_id = p.id),
        'stock_quantity', case
          when p.stock_model = 'batch_produced' then (select fg.quantity from public.finished_goods_balances fg where fg.branch_id = p_branch_id and fg.product_id = p.id)
          else null end,
        'stock_available', case
          when p.stock_model = 'batch_produced' then coalesce((select fg.quantity from public.finished_goods_balances fg where fg.branch_id = p_branch_id and fg.product_id = p.id), 0) > 0
          when p.flavor_choices = 0 and not exists(select 1 from public.product_recipes r where r.product_id = p.id) then true
          else not exists(
            select 1 from public.product_recipes r
            left join public.ingredient_balances ib on ib.branch_id = p_branch_id and ib.ingredient_id = r.ingredient_id
            where r.product_id = p.id and coalesce(ib.quantity, 0) < r.quantity
          ) end,
        'options', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', sf.id, 'name', sf.name, 'sort_order', sf.sort_order,
            'cost_centavos', coalesce((
              select round(sum(sfr.quantity * coalesce(ib.average_cost_centavos, 0)))
              from public.shop_flavor_recipes sfr
              left join public.ingredient_balances ib
                on ib.branch_id = p_branch_id and ib.ingredient_id = sfr.ingredient_id
              where sfr.flavor_id = sf.id
            ), 0)
          ) order by sf.sort_order, sf.name)
          from public.shop_flavors sf
          join public.product_flavor_links pfl on pfl.flavor_id = sf.id and pfl.product_id = p.id
          where sf.shop_id = v_shop_id and sf.active
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p
      left join public.branch_product_settings bps
        on bps.branch_id = p_branch_id and bps.product_id = p.id
      where p.shop_id = v_shop_id and p.active
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- 7. Update get_admin_data to include shop_flavors
-- Add shop_flavors to the admin data response
-- (The existing get_admin_data is in migration 20261024000008)

-- 8. Update ensure_chicken_wing_catalog to use shop_flavors
create or replace function public.ensure_chicken_wing_catalog(target_shop uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_flavor_name text;
  v_flavor_id uuid;
  v_product_id uuid;
  v_default_flavors constant text[] := array[
    'Buffalo', 'Garlic Parmesan', 'Honey Soy',
    'Korean BBQ', 'Salted Egg', 'Spicy Yangnyeom'
  ];
begin
  select group_id into v_group_id from public.shops where id = target_shop;
  if v_group_id is null
    or not public.is_group_member(v_group_id, array['super_admin','owner']::public.business_role[])
  then raise exception 'Shop configuration access denied'; end if;

  -- Create products
  insert into public.products (shop_id, name, description, price_centavos, flavor_choices, stock_model)
  values
    (target_shop, 'Solo 2-piece meal', '2 wings + 1 Java rice', 8900, 1, 'made_to_order'),
    (target_shop, 'Solo 3-piece meal', '3 wings + 1 Java rice', 11900, 1, 'made_to_order'),
    (target_shop, '6-piece wings', '6 wingette/drummette', 18900, 2, 'made_to_order'),
    (target_shop, '12-piece wings', '12 wingette/drummette', 34900, 3, 'made_to_order'),
    (target_shop, '20-piece wings', '20 wingette/drummette', 54900, 4, 'made_to_order'),
    (target_shop, '30-piece wings', '30 wingette/drummette', 79900, 5, 'made_to_order')
  on conflict (shop_id, name) do nothing;

  -- Create shop-level flavors (only if none exist yet for this shop)
  if not exists (select 1 from public.shop_flavors where shop_id = target_shop) then
    foreach v_flavor_name in array v_default_flavors loop
      insert into public.shop_flavors (shop_id, name, active, sort_order)
      values (target_shop, v_flavor_name, true,
        array_position(v_default_flavors, v_flavor_name))
      on conflict (shop_id, name) do nothing;
    end loop;
  end if;

  -- Link all flavors to all chicken-wing products that have flavor_choices > 0
  for v_product_id in
    select id from public.products
    where shop_id = target_shop and flavor_choices > 0
  loop
    for v_flavor_id in
      select id from public.shop_flavors where shop_id = target_shop and active
    loop
      insert into public.product_flavor_links (product_id, flavor_id)
      values (v_product_id, v_flavor_id)
      on conflict do nothing;
    end loop;
  end loop;
end;
$$;

comment on function public.ensure_chicken_wing_catalog(uuid) is
  'Idempotently creates the chicken-wings menu, shop-level flavors, and links them.';
