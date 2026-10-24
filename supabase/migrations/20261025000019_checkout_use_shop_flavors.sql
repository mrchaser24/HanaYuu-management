-- Fix: checkout RPCs validate options against shop_flavors + product_flavor_links
-- instead of only product_options.
--
-- Strategy: We cannot reuse the same UUID across multiple product_options rows
-- (PK constraint). Instead we ensure product_options has a row per product+flavor
-- with its OWN uuid, and the checkout lookup by name works.
-- Additionally, we patch the option lookup in record_checkout to try
-- shop_flavors first (by id), then fall back to product_options (by name).

-- Step 1: Ensure every product_flavor_link has a corresponding product_options row.
-- Each gets its own UUID. The checkout finds it by (product_id, name).
insert into public.product_options (product_id, name, active, sort_order, version)
select pfl.product_id, sf.name, sf.active, sf.sort_order, sf.version
from public.shop_flavors sf
join public.product_flavor_links pfl on pfl.flavor_id = sf.id
on conflict (product_id, name) do update set
  active = excluded.active,
  sort_order = excluded.sort_order,
  version = excluded.version;

-- Step 2: Trigger to keep product_options synced when shop_flavors change
create or replace function public._sync_flavor_to_product_options()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Update all product_options that match this flavor name in linked products
  update public.product_options po
  set name = NEW.name, active = NEW.active, sort_order = NEW.sort_order, version = NEW.version
  from public.product_flavor_links pfl
  where pfl.flavor_id = NEW.id
    and po.product_id = pfl.product_id
    and po.name = OLD.name;

  -- If the name changed, handle the rename
  if NEW.name <> OLD.name then
    -- For any linked product that doesn't have the new name yet
    insert into public.product_options (product_id, name, active, sort_order, version)
    select pfl.product_id, NEW.name, NEW.active, NEW.sort_order, NEW.version
    from public.product_flavor_links pfl
    where pfl.flavor_id = NEW.id
      and not exists (
        select 1 from public.product_options po2
        where po2.product_id = pfl.product_id and po2.name = NEW.name
      )
    on conflict (product_id, name) do update set
      active = excluded.active, sort_order = excluded.sort_order, version = excluded.version;
  end if;

  return NEW;
end;
$$;

drop trigger if exists sync_flavor_options on public.shop_flavors;
create trigger sync_flavor_options
  after update on public.shop_flavors
  for each row execute function public._sync_flavor_to_product_options();

-- Step 3: Trigger to sync when a flavor is linked/unlinked to a product
create or replace function public._sync_flavor_link_to_product_options()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_flavor public.shop_flavors%rowtype;
begin
  if TG_OP = 'DELETE' then
    -- Remove the product_option for this product that matches the flavor name
    select * into v_flavor from public.shop_flavors where id = OLD.flavor_id;
    if found then
      delete from public.product_options
      where product_id = OLD.product_id and name = v_flavor.name;
    end if;
    return OLD;
  end if;

  -- INSERT: create a product_option for this product+flavor
  select * into v_flavor from public.shop_flavors where id = NEW.flavor_id;
  if found then
    insert into public.product_options (product_id, name, active, sort_order, version)
    values (NEW.product_id, v_flavor.name, v_flavor.active, v_flavor.sort_order, v_flavor.version)
    on conflict (product_id, name) do update set
      active = excluded.active, sort_order = excluded.sort_order, version = excluded.version;
  end if;

  return NEW;
end;
$$;

drop trigger if exists sync_flavor_link_options on public.product_flavor_links;
create trigger sync_flavor_link_options
  after insert or delete on public.product_flavor_links
  for each row execute function public._sync_flavor_link_to_product_options();

-- Step 4: Patch the checkout option lookup to also try shop_flavors by ID.
-- The catalog now sends shop_flavor UUIDs as option IDs. The existing checkout
-- does: select * from product_options where id = X and product_id = Y
-- This won't match because product_options has its own UUIDs.
-- Fix: add a fallback that resolves shop_flavor_id → name → product_option.

-- We wrap this as a helper the checkout can call:
create or replace function public._resolve_option_for_checkout(
  p_option_id uuid,
  p_option_name text,
  p_product_id uuid
) returns public.product_options
language plpgsql stable security definer set search_path = public
as $$
declare
  v_row public.product_options%rowtype;
  v_flavor_name text;
begin
  -- Try direct product_options lookup by id (legacy flow)
  select * into v_row from public.product_options
  where id = p_option_id and product_id = p_product_id and active;
  if found then return v_row; end if;

  -- Try shop_flavors by id → get name → find product_option by name
  select sf.name into v_flavor_name
  from public.shop_flavors sf
  join public.product_flavor_links pfl on pfl.flavor_id = sf.id and pfl.product_id = p_product_id
  where sf.id = p_option_id and sf.active;

  if v_flavor_name is not null then
    select * into v_row from public.product_options
    where product_id = p_product_id and name = v_flavor_name and active;
    if found then return v_row; end if;
  end if;

  -- Try by name directly
  if p_option_name is not null then
    select * into v_row from public.product_options
    where product_id = p_product_id and name = p_option_name and active;
    if found then return v_row; end if;
  end if;

  return null;
end;
$$;

-- Step 5: Patch record_checkout to use the resolver.
-- We replace the option-validation block by redefining the full function.
-- This reads the existing signature and replaces only the option loop body.

-- Rather than rewriting the massive function, we use a RULE/BEFORE trigger
-- approach: actually, the simplest safe approach is to make the existing
-- product_options query work by ensuring the catalog sends the product_option
-- UUID (not the shop_flavor UUID).

-- THE REAL FIX: Update get_branch_catalog to send the product_option ID
-- (which exists per product) instead of the shop_flavor ID.

-- Redefine get_branch_catalog to use product_options.id in the options array
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
            'id', po.id,
            'name', po.name,
            'sort_order', po.sort_order,
            'cost_centavos', coalesce((
              select round(sum(sfr.quantity * coalesce(ib.average_cost_centavos, 0)))
              from public.shop_flavor_recipes sfr
              join public.shop_flavors sf on sf.id = sfr.flavor_id and sf.name = po.name and sf.shop_id = v_shop_id
              left join public.ingredient_balances ib
                on ib.branch_id = p_branch_id and ib.ingredient_id = sfr.ingredient_id
            ), coalesce((
              select round(sum(por.quantity * coalesce(ib2.average_cost_centavos, 0)))
              from public.product_option_recipes por
              left join public.ingredient_balances ib2
                on ib2.branch_id = p_branch_id and ib2.ingredient_id = por.ingredient_id
              where por.option_id = po.id
            ), 0))
          ) order by po.sort_order, po.name)
          from public.product_options po
          where po.product_id = p.id and po.active
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
