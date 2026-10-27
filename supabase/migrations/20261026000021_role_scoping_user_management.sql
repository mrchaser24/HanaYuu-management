-- ============================================================
-- Role-scoped visibility + editable team memberships
--
-- super_admin : all shops, branches, members, and devices in the group
-- owner       : their assigned shop and all branches in that shop
-- staff       : their assigned shop and assigned branch only
-- ============================================================

-- Membership rows are visible to the member themselves, super admins, and the
-- owner of the shop the staff member belongs to. Security definer avoids
-- recursive RLS checks on the memberships table.
create or replace function public.can_view_membership(
  p_user_id uuid,
  p_group_id uuid,
  p_shop_id uuid,
  p_role public.business_role
) returns boolean
language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null and (
    p_user_id = auth.uid()
    or public.is_group_member(p_group_id, array['super_admin']::public.business_role[])
    or (
      p_role = 'staff'
      and p_shop_id is not null
      and exists (
        select 1
        from public.memberships owner_m
        where owner_m.user_id = auth.uid()
          and owner_m.group_id = p_group_id
          and owner_m.role = 'owner'
          and owner_m.shop_id = p_shop_id
      )
    )
  );
$$;

drop policy if exists "members see shops" on public.shops;
drop policy if exists "members see scoped shops" on public.shops;
create policy "members see scoped shops" on public.shops
  for select using (public.can_access_shop(id));

drop policy if exists "members see products" on public.products;
drop policy if exists "members see scoped products" on public.products;
create policy "members see scoped products" on public.products
  for select using (public.can_access_shop(shop_id));

drop policy if exists "members see ingredients" on public.ingredients;
drop policy if exists "members see scoped ingredients" on public.ingredients;
create policy "members see scoped ingredients" on public.ingredients
  for select using (public.can_access_shop(shop_id));

drop policy if exists "members see product options" on public.product_options;
drop policy if exists "members see scoped product options" on public.product_options;
create policy "members see scoped product options" on public.product_options
  for select using ((
    select public.can_access_shop(p.shop_id)
    from public.products p
    where p.id = product_id
  ));

drop policy if exists "members see recipes" on public.product_recipes;
drop policy if exists "members see scoped recipes" on public.product_recipes;
create policy "members see scoped recipes" on public.product_recipes
  for select using ((
    select public.can_access_shop(p.shop_id)
    from public.products p
    where p.id = product_id
  ));

drop policy if exists "members see memberships in group" on public.memberships;
drop policy if exists "members see scoped memberships" on public.memberships;
create policy "members see scoped memberships" on public.memberships
  for select using (public.can_view_membership(user_id, group_id, shop_id, role));

drop policy if exists "members see audit in group" on public.audit_events;
drop policy if exists "members see scoped audit" on public.audit_events;
create policy "members see scoped audit" on public.audit_events
  for select using (
    public.is_group_member(group_id, array['super_admin']::public.business_role[])
    or (branch_id is not null and public.can_access_branch(branch_id))
    or (
      branch_id is null
      and shop_id is not null
      and exists (
        select 1
        from public.memberships owner_m
        where owner_m.user_id = auth.uid()
          and owner_m.group_id = audit_events.group_id
          and owner_m.role = 'owner'
          and owner_m.shop_id = audit_events.shop_id
      )
    )
  );

drop policy if exists "members see shop flavors" on public.shop_flavors;
drop policy if exists "members see scoped shop flavors" on public.shop_flavors;
create policy "members see scoped shop flavors" on public.shop_flavors
  for select using (public.can_access_shop(shop_id));

drop policy if exists "members see flavor links" on public.product_flavor_links;
drop policy if exists "members see scoped flavor links" on public.product_flavor_links;
create policy "members see scoped flavor links" on public.product_flavor_links
  for select using ((
    select public.can_access_shop(p.shop_id)
    from public.products p
    where p.id = product_id
  ));

drop policy if exists "members see flavor recipes" on public.shop_flavor_recipes;
drop policy if exists "members see scoped flavor recipes" on public.shop_flavor_recipes;
create policy "members see scoped flavor recipes" on public.shop_flavor_recipes
  for select using ((
    select public.can_access_shop(f.shop_id)
    from public.shop_flavors f
    where f.id = flavor_id
  ));

revoke all on function public.can_view_membership(uuid, uuid, uuid, public.business_role) from public;
grant execute on function public.can_view_membership(uuid, uuid, uuid, public.business_role) to authenticated;

-- ------------------------------------------------------------
-- Update a member's role/scope.
--   super_admin -> can update owners and staff
--   owner       -> can update staff in their own shop only
-- Super admin memberships themselves cannot be edited or granted here.
-- ------------------------------------------------------------
create or replace function public.update_membership(
  p_membership_id uuid,
  p_role public.business_role,
  p_shop_id uuid default null,
  p_branch_id uuid default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_m public.memberships%rowtype;
  v_is_super boolean;
  v_is_owner boolean;
  v_group_id uuid;
  v_branch_shop uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_m from public.memberships where id = p_membership_id for update;
  if not found then raise exception 'Membership not found'; end if;
  if v_m.role = 'super_admin' then raise exception 'Super admin memberships cannot be edited'; end if;
  if p_role not in ('owner', 'staff') then raise exception 'Only owner and staff roles can be assigned'; end if;

  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = v_m.group_id and m.role = 'super_admin'
  ) into v_is_super;

  select exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid()
      and m.group_id = v_m.group_id
      and m.role = 'owner'
      and m.shop_id = v_m.shop_id
  ) into v_is_owner;

  if not v_is_super and not (v_is_owner and v_m.role = 'staff' and p_role = 'staff') then
    raise exception 'Membership management access denied';
  end if;

  if p_role = 'owner' then
    if p_shop_id is null or p_branch_id is not null then
      raise exception 'Owners require a shop and no branch';
    end if;
    select group_id into v_group_id from public.shops where id = p_shop_id;
    if v_group_id is distinct from v_m.group_id then
      raise exception 'Shop does not belong to this business';
    end if;
  else
    if p_branch_id is null then raise exception 'Staff require a branch'; end if;
    select b.shop_id, s.group_id into v_branch_shop, v_group_id
    from public.branches b join public.shops s on s.id = b.shop_id
    where b.id = p_branch_id;
    if v_branch_shop is null or v_group_id is distinct from v_m.group_id then
      raise exception 'Branch does not belong to this business';
    end if;
    if p_shop_id is not null and p_shop_id is distinct from v_branch_shop then
      raise exception 'Branch does not belong to this shop';
    end if;
    p_shop_id := v_branch_shop;

    if not v_is_super and v_branch_shop is distinct from v_m.shop_id then
      raise exception 'Staff can only be moved within your shop';
    end if;
  end if;

  update public.memberships
  set role = p_role,
      shop_id = p_shop_id,
      branch_id = case when p_role = 'staff' then p_branch_id else null end
  where id = p_membership_id;

  insert into public.audit_events (group_id, shop_id, branch_id, actor_id, action, entity_type, entity_id, metadata)
  values (
    v_m.group_id, p_shop_id, case when p_role = 'staff' then p_branch_id else null end,
    auth.uid(), 'membership_updated', 'membership', p_membership_id,
    jsonb_build_object(
      'user_id', v_m.user_id,
      'old_role', v_m.role,
      'new_role', p_role,
      'old_shop_id', v_m.shop_id,
      'new_shop_id', p_shop_id,
      'old_branch_id', v_m.branch_id,
      'new_branch_id', case when p_role = 'staff' then p_branch_id else null end
    )
  );
end;
$$;

revoke all on function public.update_membership(uuid, public.business_role, uuid, uuid) from public;
grant execute on function public.update_membership(uuid, public.business_role, uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- Fully scope admin data. The previous definition only scoped members and
-- devices, which exposed every shop's products, settings, and branches to
-- owners. Super admins still see every shop in the group.
-- ------------------------------------------------------------
create or replace function public.get_admin_data(p_group_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_group_id uuid;
  v_is_super boolean;
  v_is_owner boolean;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  v_group_id := p_group_id;
  if v_group_id is null then
    select group_id into v_group_id
    from public.memberships
    where user_id = auth.uid()
    order by created_at
    limit 1;
  end if;
  if v_group_id is null or not public.is_group_member(v_group_id) then
    raise exception 'Group access denied';
  end if;

  select exists (
    select 1 from public.memberships
    where user_id = auth.uid() and group_id = v_group_id and role = 'super_admin'
  ) into v_is_super;

  select v_is_super or exists (
    select 1 from public.memberships
    where user_id = auth.uid() and group_id = v_group_id and role = 'owner'
  ) into v_is_owner;

  if not v_is_owner then raise exception 'Owner or super admin access required'; end if;

  return jsonb_build_object(
    'group', (select to_jsonb(g) from public.business_groups g where g.id = v_group_id),
    'shops', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.name)
      from public.shops s
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'branches', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.name)
      from public.branches b
      join public.shops s on s.id = b.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'user_id', m.user_id,
        'role', m.role,
        'shop_id', m.shop_id,
        'branch_id', m.branch_id,
        'display_name', pr.display_name,
        'email', u.email,
        'created_at', m.created_at
      ) order by m.created_at)
      from public.memberships m
      left join public.profiles pr on pr.id = m.user_id
      left join auth.users u on u.id = m.user_id
      where m.group_id = v_group_id
        and (
          v_is_super
          or (m.role = 'staff' and public.can_manage_shop(m.shop_id))
        )
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id,
        'branch_id', d.branch_id,
        'user_id', d.user_id,
        'device_label', d.device_label,
        'created_at', d.created_at,
        'last_seen_at', d.last_seen_at,
        'revoked_at', d.revoked_at,
        'revoked_reason', d.revoked_reason,
        'wipe_requested_at', d.wipe_requested_at
      ) order by d.created_at desc)
      from public.branch_devices d
      join public.branches b on b.id = d.branch_id
      join public.shops s on s.id = b.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'shop_id', p.shop_id,
        'name', p.name,
        'description', p.description,
        'price_centavos', p.price_centavos,
        'flavor_choices', p.flavor_choices,
        'stock_model', p.stock_model,
        'expected_yield_quantity', p.expected_yield_quantity,
        'expected_yield_unit', p.expected_yield_unit,
        'pieces', p.pieces,
        'rice_included', p.rice_included,
        'active', p.active,
        'version', p.version,
        'options', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', o.id,
            'name', o.name,
            'active', o.active,
            'sort_order', o.sort_order,
            'version', o.version,
            'recipes', coalesce((
              select jsonb_agg(jsonb_build_object(
                'ingredient_id', por.ingredient_id,
                'quantity', por.quantity,
                'name', i.name,
                'base_unit', i.base_unit
              ))
              from public.product_option_recipes por
              join public.ingredients i on i.id = por.ingredient_id
              where por.option_id = o.id
            ), '[]'::jsonb)
          ) order by o.sort_order, o.name)
          from public.product_options o
          where o.product_id = p.id
        ), '[]'::jsonb),
        'recipe', coalesce((
          select jsonb_agg(jsonb_build_object(
            'ingredient_id', r.ingredient_id,
            'quantity', r.quantity,
            'name', i.name,
            'base_unit', i.base_unit
          ))
          from public.product_recipes r
          join public.ingredients i on i.id = r.ingredient_id
          where r.product_id = p.id
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p
      join public.shops s on s.id = p.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'ingredients', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.name)
      from public.ingredients i
      join public.shops s on s.id = i.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm
      join public.shops s on s.id = pm.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb),
    'settings', coalesce((
      select jsonb_agg(to_jsonb(ss) order by ss.shop_id)
      from public.shop_settings ss
      join public.shops s on s.id = ss.shop_id
      where s.group_id = v_group_id and public.can_manage_shop(s.id)
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_admin_data(uuid) from public;
grant execute on function public.get_admin_data(uuid) to authenticated;
