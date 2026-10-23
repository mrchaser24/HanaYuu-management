-- Device registration/revocation and owner/super-admin configuration commands.

create or replace function public.register_device(
  p_branch_id uuid,
  p_label text
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  if p_label is null or char_length(trim(p_label)) < 2 then raise exception 'A device label is required'; end if;
  select s.group_id into v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;
  insert into public.branch_devices (branch_id, user_id, device_label, device_key_hash)
  values (p_branch_id, auth.uid(), trim(p_label), encode(extensions.gen_random_bytes(32), 'hex'))
  returning id into v_id;
  insert into public.audit_events (group_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_branch_id, auth.uid(), 'device_registered', 'branch_device', v_id,
    jsonb_build_object('label', p_label));
  return v_id;
end;
$$;

create or replace function public.revoke_device(
  p_device_id uuid,
  p_reason text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_device public.branch_devices%rowtype;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_device from public.branch_devices where id = p_device_id for update;
  if not found then raise exception 'Device not found'; end if;
  if not public.can_manage_branch(v_device.branch_id) then raise exception 'Device management access denied'; end if;
  select s.group_id into v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_device.branch_id;
  update public.branch_devices set
    revoked_at = coalesce(revoked_at, now()), revoked_by = auth.uid(),
    revoked_reason = nullif(trim(p_reason), ''), version = version + 1
  where id = p_device_id;
  insert into public.audit_events (group_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_device.branch_id, auth.uid(), 'device_revoked', 'branch_device', p_device_id,
    jsonb_build_object('reason', p_reason));
end;
$$;

create or replace function public.request_device_wipe(p_device_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_device public.branch_devices%rowtype;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_device from public.branch_devices where id = p_device_id for update;
  if not found then raise exception 'Device not found'; end if;
  if not public.can_manage_branch(v_device.branch_id) then raise exception 'Device management access denied'; end if;
  select s.group_id into v_group_id
  from public.branches b join public.shops s on s.id = b.shop_id where b.id = v_device.branch_id;
  update public.branch_devices set wipe_requested_at = now(), version = version + 1 where id = p_device_id;
  insert into public.audit_events (group_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_device.branch_id, auth.uid(), 'device_wipe_requested', 'branch_device', p_device_id, '{}'::jsonb);
end;
$$;

create or replace function public.create_shop(p_group_id uuid, p_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_group_member(p_group_id, array['super_admin']::public.business_role[]) then
    raise exception 'Shop creation access denied';
  end if;
  if p_name is null or char_length(trim(p_name)) < 2 then raise exception 'A shop name is required'; end if;
  insert into public.shops (group_id, name) values (p_group_id, trim(p_name)) returning id into v_id;
  insert into public.shop_settings (shop_id) values (v_id);
  insert into public.payment_methods (shop_id, code, name, kind, requires_reference, sort_order)
  values
    (v_id, 'cash', 'Cash', 'cash', false, 1),
    (v_id, 'gcash', 'GCash', 'gcash', true, 2)
  on conflict (shop_id, code) do nothing;
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_group_id, v_id, auth.uid(), 'shop_created', 'shop', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.create_branch(p_shop_id uuid, p_name text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_shop(p_shop_id) then raise exception 'Branch creation access denied'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 then raise exception 'A branch name is required'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;
  insert into public.branches (shop_id, name) values (p_shop_id, trim(p_name)) returning id into v_id;
  insert into public.audit_events (group_id, shop_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, v_id, auth.uid(), 'branch_created', 'branch', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.add_membership(
  p_email text,
  p_role public.business_role,
  p_group_id uuid,
  p_shop_id uuid default null,
  p_branch_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_user_id uuid;
  v_id uuid;
  v_is_super boolean;
  v_is_owner boolean;
  v_shop_group uuid;
  v_branch_shop uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_email is null then raise exception 'An email is required'; end if;

  select id into v_user_id from auth.users where lower(email) = lower(trim(p_email)) limit 1;
  if v_user_id is null then raise exception 'No account exists for that email'; end if;

  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = p_group_id and m.role = 'super_admin'
  ) into v_is_super;
  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = p_group_id and m.role = 'owner' and m.shop_id = p_shop_id
  ) into v_is_owner;

  if not v_is_super and not (v_is_owner and p_role = 'staff') then
    raise exception 'Membership management access denied';
  end if;

  if p_role = 'super_admin' then
    if p_shop_id is not null or p_branch_id is not null then raise exception 'Super admins cannot be scoped to a shop or branch'; end if;
  elsif p_role = 'owner' then
    if p_shop_id is null or p_branch_id is not null then raise exception 'Owners require a shop and no branch'; end if;
    select group_id into v_shop_group from public.shops where id = p_shop_id;
    if v_shop_group is distinct from p_group_id then raise exception 'Shop does not belong to this group'; end if;
  else
    if p_branch_id is null then raise exception 'Staff require a branch'; end if;
    select b.shop_id, s.group_id into v_branch_shop, v_shop_group
    from public.branches b join public.shops s on s.id = b.shop_id where b.id = p_branch_id;
    if v_branch_shop is null or v_shop_group is distinct from p_group_id then raise exception 'Branch does not belong to this group'; end if;
    if p_shop_id is null then p_shop_id := v_branch_shop; end if;
    if p_shop_id is distinct from v_branch_shop then raise exception 'Branch does not belong to this shop'; end if;
  end if;

  insert into public.memberships (user_id, group_id, shop_id, branch_id, role)
  values (v_user_id, p_group_id, p_shop_id, p_branch_id, p_role)
  returning id into v_id;
  insert into public.audit_events (group_id, shop_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_group_id, p_shop_id, p_branch_id, auth.uid(), 'membership_added', 'membership', v_id,
    jsonb_build_object('user_id', v_user_id, 'role', p_role));
  return v_id;
end;
$$;

create or replace function public.remove_membership(p_membership_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_m public.memberships%rowtype;
  v_is_super boolean;
  v_is_owner boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_m from public.memberships where id = p_membership_id;
  if not found then raise exception 'Membership not found'; end if;
  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = v_m.group_id and m.role = 'super_admin'
  ) into v_is_super;
  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = v_m.group_id and m.role = 'owner'
      and m.shop_id = v_m.shop_id and v_m.role = 'staff'
  ) into v_is_owner;
  if not v_is_super and not v_is_owner then raise exception 'Membership management access denied'; end if;
  if v_m.role = 'super_admin' and (
    select count(*) from public.memberships where group_id = v_m.group_id and role = 'super_admin'
  ) <= 1 then raise exception 'At least one super admin is required'; end if;
  delete from public.memberships where id = p_membership_id;
  insert into public.audit_events (group_id, shop_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_m.group_id, v_m.shop_id, v_m.branch_id, auth.uid(), 'membership_removed', 'membership', p_membership_id,
    jsonb_build_object('user_id', v_m.user_id, 'role', v_m.role));
end;
$$;

create or replace function public.upsert_product(
  p_shop_id uuid,
  p_product_id uuid,
  p_name text,
  p_description text,
  p_price_centavos integer,
  p_flavor_choices smallint,
  p_stock_model public.stock_model,
  p_expected_yield_quantity numeric default 1,
  p_expected_yield_unit text default 'serving',
  p_pieces smallint default null,
  p_rice_included boolean default false,
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
  if not public.can_manage_shop(p_shop_id) then raise exception 'Product configuration access denied'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 then raise exception 'A product name is required'; end if;
  if p_price_centavos is null or p_price_centavos < 0 then raise exception 'Price cannot be negative'; end if;
  if p_flavor_choices < 0 or p_flavor_choices > 10 then raise exception 'Invalid flavor choice count'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;

  if p_product_id is null then
    insert into public.products (shop_id, name, description, price_centavos, flavor_choices, stock_model,
      expected_yield_quantity, expected_yield_unit, pieces, rice_included, active)
    values (p_shop_id, trim(p_name), coalesce(p_description, ''), p_price_centavos, p_flavor_choices, p_stock_model,
      coalesce(p_expected_yield_quantity, 1), coalesce(p_expected_yield_unit, 'serving'), p_pieces,
      coalesce(p_rice_included, false), coalesce(p_active, true))
    returning id into v_id;
  else
    select version into v_current from public.products where id = p_product_id and shop_id = p_shop_id;
    if v_current is null then raise exception 'Product not found'; end if;
    if p_version is not null and p_version <> v_current then raise exception 'Product changed; refresh and review'; end if;
    update public.products set
      name = trim(p_name), description = coalesce(p_description, ''), price_centavos = p_price_centavos,
      flavor_choices = p_flavor_choices, stock_model = p_stock_model,
      expected_yield_quantity = coalesce(p_expected_yield_quantity, expected_yield_quantity),
      expected_yield_unit = coalesce(p_expected_yield_unit, expected_yield_unit),
      pieces = p_pieces, rice_included = coalesce(p_rice_included, rice_included),
      active = coalesce(p_active, active), retired_at = case when coalesce(p_active, active) then null else coalesce(retired_at, now()) end,
      version = version + 1
    where id = p_product_id and shop_id = p_shop_id;
    v_id := p_product_id;
  end if;
  perform public.bump_shop_config(p_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'product_saved', 'product', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.upsert_product_option(
  p_product_id uuid,
  p_option_id uuid,
  p_name text,
  p_active boolean default true,
  p_sort_order integer default 0,
  p_version integer default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
  v_shop_id uuid;
  v_group_id uuid;
  v_current integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select p.shop_id, s.group_id into v_shop_id, v_group_id
  from public.products p join public.shops s on s.id = p.shop_id where p.id = p_product_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Option configuration access denied'; end if;
  if p_name is null or char_length(trim(p_name)) < 1 then raise exception 'An option name is required'; end if;
  if p_option_id is null then
    insert into public.product_options (product_id, name, active, sort_order)
    values (p_product_id, trim(p_name), coalesce(p_active, true), coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    select version into v_current from public.product_options where id = p_option_id and product_id = p_product_id;
    if v_current is null then raise exception 'Option not found'; end if;
    if p_version is not null and p_version <> v_current then raise exception 'Option changed; refresh and review'; end if;
    update public.product_options set name = trim(p_name), active = coalesce(p_active, active),
      sort_order = coalesce(p_sort_order, sort_order), version = version + 1
    where id = p_option_id and product_id = p_product_id;
    v_id := p_option_id;
  end if;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'option_saved', 'product_option', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.set_branch_product_availability(
  p_branch_id uuid,
  p_product_id uuid,
  p_available boolean,
  p_version integer default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
  v_current integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_branch(p_branch_id) then raise exception 'Availability management access denied'; end if;
  select shop_id into v_shop_id from public.branches where id = p_branch_id;
  if not exists (select 1 from public.products where id = p_product_id and shop_id = v_shop_id) then
    raise exception 'Product does not belong to this shop';
  end if;
  select s.group_id into v_group_id from public.shops s where s.id = v_shop_id;
  select version into v_current from public.branch_product_settings where branch_id = p_branch_id and product_id = p_product_id;
  if p_version is not null and v_current is not null and p_version <> v_current then
    raise exception 'Availability changed; refresh and review';
  end if;
  insert into public.branch_product_settings (branch_id, product_id, available, updated_by)
  values (p_branch_id, p_product_id, coalesce(p_available, true), auth.uid())
  on conflict (branch_id, product_id) do update set
    available = excluded.available, updated_by = auth.uid(), updated_at = now(), version = public.branch_product_settings.version + 1;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, p_branch_id, auth.uid(), 'product_availability_changed', 'product', p_product_id,
    jsonb_build_object('available', p_available));
end;
$$;

create or replace function public.upsert_ingredient(
  p_shop_id uuid,
  p_ingredient_id uuid,
  p_name text,
  p_base_unit text,
  p_low_stock_quantity numeric default 0,
  p_category text default 'other',
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
  if p_base_unit not in ('g', 'ml', 'piece') then raise exception 'Invalid base unit'; end if;
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

create or replace function public.upsert_recipe_component(
  p_product_id uuid,
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
  select shop_id into v_shop_id from public.products where id = p_product_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Recipe configuration access denied'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Recipe quantity must be positive'; end if;
  if not exists (select 1 from public.ingredients where id = p_ingredient_id and shop_id = v_shop_id) then
    raise exception 'Ingredient does not belong to this shop';
  end if;
  select s.group_id into v_group_id from public.shops s where s.id = v_shop_id;
  insert into public.product_recipes (product_id, ingredient_id, quantity)
  values (p_product_id, p_ingredient_id, p_quantity)
  on conflict (product_id, ingredient_id) do update set quantity = excluded.quantity
  returning id into v_id;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'recipe_component_saved', 'product_recipe', v_id,
    jsonb_build_object('product_id', p_product_id, 'ingredient_id', p_ingredient_id, 'quantity', p_quantity));
  return v_id;
end;
$$;

create or replace function public.delete_recipe_component(p_product_id uuid, p_ingredient_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select shop_id into v_shop_id from public.products where id = p_product_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Recipe configuration access denied'; end if;
  select s.group_id into v_group_id from public.shops s where s.id = v_shop_id;
  delete from public.product_recipes where product_id = p_product_id and ingredient_id = p_ingredient_id;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'recipe_component_deleted', 'product_recipe', p_product_id,
    jsonb_build_object('ingredient_id', p_ingredient_id));
end;
$$;

create or replace function public.upsert_option_recipe(
  p_option_id uuid,
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
  select p.shop_id into v_shop_id
  from public.product_options o join public.products p on p.id = o.product_id where o.id = p_option_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Option recipe access denied'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'Recipe quantity must be positive'; end if;
  if not exists (select 1 from public.ingredients where id = p_ingredient_id and shop_id = v_shop_id) then
    raise exception 'Ingredient does not belong to this shop';
  end if;
  select s.group_id into v_group_id from public.shops s where s.id = v_shop_id;
  insert into public.product_option_recipes (option_id, ingredient_id, quantity)
  values (p_option_id, p_ingredient_id, p_quantity)
  on conflict (option_id, ingredient_id) do update set quantity = excluded.quantity
  returning id into v_id;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'option_recipe_saved', 'product_option_recipe', v_id,
    jsonb_build_object('option_id', p_option_id, 'ingredient_id', p_ingredient_id, 'quantity', p_quantity));
  return v_id;
end;
$$;

create or replace function public.delete_option_recipe(p_option_id uuid, p_ingredient_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select p.shop_id into v_shop_id
  from public.product_options o join public.products p on p.id = o.product_id where o.id = p_option_id;
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Option recipe access denied'; end if;
  select s.group_id into v_group_id from public.shops s where s.id = v_shop_id;
  delete from public.product_option_recipes where option_id = p_option_id and ingredient_id = p_ingredient_id;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'option_recipe_deleted', 'product_option_recipe', p_option_id,
    jsonb_build_object('ingredient_id', p_ingredient_id));
end;
$$;

create or replace function public.upsert_payment_method(
  p_shop_id uuid,
  p_method_id uuid,
  p_code text,
  p_name text,
  p_kind public.payment_kind,
  p_requires_reference boolean default false,
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
  if not public.can_manage_shop(p_shop_id) then raise exception 'Payment configuration access denied'; end if;
  if p_code is null or char_length(trim(p_code)) < 2 then raise exception 'A method code is required'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 then raise exception 'A method name is required'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;
  if p_method_id is null then
    insert into public.payment_methods (shop_id, code, name, kind, requires_reference, active, sort_order)
    values (p_shop_id, lower(trim(p_code)), trim(p_name), p_kind, coalesce(p_requires_reference, false), coalesce(p_active, true), coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    select version into v_current from public.payment_methods where id = p_method_id and shop_id = p_shop_id;
    if v_current is null then raise exception 'Payment method not found'; end if;
    if p_version is not null and p_version <> v_current then raise exception 'Payment method changed; refresh and review'; end if;
    update public.payment_methods set code = lower(trim(p_code)), name = trim(p_name), kind = p_kind,
      requires_reference = coalesce(p_requires_reference, requires_reference),
      active = coalesce(p_active, active), sort_order = coalesce(p_sort_order, sort_order),
      updated_at = now(), version = version + 1
    where id = p_method_id and shop_id = p_shop_id;
    v_id := p_method_id;
  end if;
  perform public.bump_shop_config(p_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'payment_method_saved', 'payment_method', v_id, jsonb_build_object('name', p_name));
  return v_id;
end;
$$;

create or replace function public.update_shop_settings(
  p_shop_id uuid,
  p_tax_inclusive_enabled boolean,
  p_tax_rate_bps integer,
  p_receipt_footer text,
  p_version integer default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_current integer;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_shop(p_shop_id) then raise exception 'Settings access denied'; end if;
  if p_tax_rate_bps is null or p_tax_rate_bps < 0 or p_tax_rate_bps > 10000 then raise exception 'Invalid tax rate'; end if;
  select group_id into v_group_id from public.shops where id = p_shop_id;
  select version into v_current from public.shop_settings where shop_id = p_shop_id;
  if v_current is null then
    insert into public.shop_settings (shop_id, tax_inclusive_enabled, tax_rate_bps, receipt_footer, updated_by)
    values (p_shop_id, coalesce(p_tax_inclusive_enabled, false), p_tax_rate_bps, coalesce(p_receipt_footer, ''), auth.uid());
  else
    if p_version is not null and p_version <> v_current then raise exception 'Settings changed; refresh and review'; end if;
    update public.shop_settings set tax_inclusive_enabled = coalesce(p_tax_inclusive_enabled, tax_inclusive_enabled),
      tax_rate_bps = p_tax_rate_bps, receipt_footer = coalesce(p_receipt_footer, receipt_footer),
      updated_by = auth.uid(), updated_at = now(), version = version + 1
    where shop_id = p_shop_id;
  end if;
  perform public.bump_shop_config(p_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'shop_settings_updated', 'shop_settings', p_shop_id,
    jsonb_build_object('tax_inclusive_enabled', p_tax_inclusive_enabled, 'tax_rate_bps', p_tax_rate_bps));
end;
$$;

create or replace function public.get_admin_data(p_group_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_group_id uuid;
  v_is_super boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_group_id := p_group_id;
  if v_group_id is null then
    select group_id into v_group_id from public.memberships where user_id = auth.uid() order by created_at limit 1;
  end if;
  if v_group_id is null or not public.is_group_member(v_group_id) then raise exception 'Group access denied'; end if;
  select exists (
    select 1 from public.memberships where user_id = auth.uid() and group_id = v_group_id and role = 'super_admin'
  ) into v_is_super;
  if not v_is_super and not exists (
    select 1 from public.memberships where user_id = auth.uid() and group_id = v_group_id and role = 'owner'
  ) then
    raise exception 'Configuration access denied';
  end if;

  return jsonb_build_object(
    'group', (select to_jsonb(g) from public.business_groups g where g.id = v_group_id),
    'shops', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.name) from public.shops s
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'branches', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.name)
      from public.branches b join public.shops s on s.id = b.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'user_id', m.user_id, 'role', m.role, 'shop_id', m.shop_id,
        'branch_id', m.branch_id, 'display_name', pr.display_name, 'created_at', m.created_at
      ) order by m.created_at)
      from public.memberships m left join public.profiles pr on pr.id = m.user_id
      where m.group_id = v_group_id
        and (v_is_super or (m.role = 'staff' and exists (
          select 1 from public.memberships owner_m
          where owner_m.user_id = auth.uid() and owner_m.role = 'owner' and owner_m.shop_id = m.shop_id
        )))
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'branch_id', d.branch_id, 'user_id', d.user_id, 'device_label', d.device_label,
        'created_at', d.created_at, 'last_seen_at', d.last_seen_at, 'revoked_at', d.revoked_at,
        'revoked_reason', d.revoked_reason, 'wipe_requested_at', d.wipe_requested_at
      ) order by d.created_at desc)
      from public.branch_devices d
      join public.branches b on b.id = d.branch_id join public.shops s on s.id = b.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'shop_id', p.shop_id, 'name', p.name, 'description', p.description,
        'price_centavos', p.price_centavos, 'flavor_choices', p.flavor_choices, 'stock_model', p.stock_model,
        'expected_yield_quantity', p.expected_yield_quantity, 'expected_yield_unit', p.expected_yield_unit,
        'pieces', p.pieces, 'rice_included', p.rice_included, 'active', p.active, 'version', p.version,
        'options', coalesce((
          select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'active', o.active, 'sort_order', o.sort_order, 'version', o.version)
            order by o.sort_order, o.name)
          from public.product_options o where o.product_id = p.id
        ), '[]'::jsonb),
        'recipe', coalesce((
          select jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'quantity', r.quantity, 'name', i.name, 'base_unit', i.base_unit))
          from public.product_recipes r join public.ingredients i on i.id = r.ingredient_id where r.product_id = p.id
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p join public.shops s on s.id = p.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'ingredients', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.name)
      from public.ingredients i join public.shops s on s.id = i.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm join public.shops s on s.id = pm.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb),
    'settings', coalesce((
      select jsonb_agg(to_jsonb(ss) order by ss.shop_id)
      from public.shop_settings ss join public.shops s on s.id = ss.shop_id
      where s.group_id = v_group_id
        and (v_is_super or exists (
          select 1 from public.memberships m where m.user_id = auth.uid() and m.shop_id = s.id and m.role = 'owner'
        ))
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_pending_reviews(p_branch_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select o.id, o.total_centavos, o.created_at, o.review_reason, o.request_id, o.device_id,
             pr.display_name as cashier_name,
             (select coalesce(jsonb_agg(l.product_name), '[]'::jsonb) from public.order_lines l where l.order_id = o.id) as item_names
      from public.orders o left join public.profiles pr on pr.id = o.cashier_id
      where o.branch_id = p_branch_id and o.status = 'needs_review'
      order by o.created_at desc
    ) x
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.register_device(uuid, text) from public;
revoke all on function public.revoke_device(uuid, text) from public;
revoke all on function public.request_device_wipe(uuid) from public;
revoke all on function public.create_shop(uuid, text) from public;
revoke all on function public.create_branch(uuid, text) from public;
revoke all on function public.add_membership(text, public.business_role, uuid, uuid, uuid) from public;
revoke all on function public.remove_membership(uuid) from public;
revoke all on function public.upsert_product(uuid, uuid, text, text, integer, smallint, public.stock_model, numeric, text, smallint, boolean, boolean, integer) from public;
revoke all on function public.upsert_product_option(uuid, uuid, text, boolean, integer, integer) from public;
revoke all on function public.set_branch_product_availability(uuid, uuid, boolean, integer) from public;
revoke all on function public.upsert_ingredient(uuid, uuid, text, text, numeric, text, boolean, integer) from public;
revoke all on function public.upsert_recipe_component(uuid, uuid, numeric) from public;
revoke all on function public.delete_recipe_component(uuid, uuid) from public;
revoke all on function public.upsert_option_recipe(uuid, uuid, numeric) from public;
revoke all on function public.delete_option_recipe(uuid, uuid) from public;
revoke all on function public.upsert_payment_method(uuid, uuid, text, text, public.payment_kind, boolean, boolean, integer, integer) from public;
revoke all on function public.update_shop_settings(uuid, boolean, integer, text, integer) from public;
revoke all on function public.get_admin_data(uuid) from public;
revoke all on function public.get_pending_reviews(uuid) from public;

grant execute on function public.register_device(uuid, text) to authenticated;
grant execute on function public.revoke_device(uuid, text) to authenticated;
grant execute on function public.request_device_wipe(uuid) to authenticated;
grant execute on function public.create_shop(uuid, text) to authenticated;
grant execute on function public.create_branch(uuid, text) to authenticated;
grant execute on function public.add_membership(text, public.business_role, uuid, uuid, uuid) to authenticated;
grant execute on function public.remove_membership(uuid) to authenticated;
grant execute on function public.upsert_product(uuid, uuid, text, text, integer, smallint, public.stock_model, numeric, text, smallint, boolean, boolean, integer) to authenticated;
grant execute on function public.upsert_product_option(uuid, uuid, text, boolean, integer, integer) to authenticated;
grant execute on function public.set_branch_product_availability(uuid, uuid, boolean, integer) to authenticated;
grant execute on function public.upsert_ingredient(uuid, uuid, text, text, numeric, text, boolean, integer) to authenticated;
grant execute on function public.upsert_recipe_component(uuid, uuid, numeric) to authenticated;
grant execute on function public.delete_recipe_component(uuid, uuid) to authenticated;
grant execute on function public.upsert_option_recipe(uuid, uuid, numeric) to authenticated;
grant execute on function public.delete_option_recipe(uuid, uuid) to authenticated;
grant execute on function public.upsert_payment_method(uuid, uuid, text, text, public.payment_kind, boolean, boolean, integer, integer) to authenticated;
grant execute on function public.update_shop_settings(uuid, boolean, integer, text, integer) to authenticated;
grant execute on function public.get_admin_data(uuid) to authenticated;
grant execute on function public.get_pending_reviews(uuid) to authenticated;
