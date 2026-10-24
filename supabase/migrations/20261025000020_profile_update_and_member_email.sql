-- 1. RPC for users to update their own display name
create or replace function public.update_profile(p_display_name text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_display_name is null or char_length(trim(p_display_name)) < 2 then
    raise exception 'Display name must be at least 2 characters';
  end if;
  update public.profiles
  set display_name = trim(p_display_name)
  where id = auth.uid();
  if not found then
    insert into public.profiles (id, display_name)
    values (auth.uid(), trim(p_display_name));
  end if;
end;
$$;

revoke all on function public.update_profile(text) from public;
grant execute on function public.update_profile(text) to authenticated;

-- 2. Add email to get_admin_data members list
--    We read from auth.users which is accessible in SECURITY DEFINER context
drop function if exists public.get_admin_data(uuid);
create or replace function public.get_admin_data(p_group_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_group_id uuid := p_group_id;
  v_is_super boolean;
  v_is_owner boolean;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_group_member(v_group_id) then raise exception 'Group access denied'; end if;

  v_is_super := exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = v_group_id and m.role = 'super_admin'
  );
  v_is_owner := v_is_super or exists (
    select 1 from public.memberships m
    where m.user_id = auth.uid() and m.group_id = v_group_id and m.role = 'owner'
  );

  if not v_is_owner then raise exception 'Owner or super admin access required'; end if;

  select jsonb_build_object(
    'group', (select to_jsonb(g) from public.business_groups g where g.id = v_group_id),
    'shops', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.name)
      from public.shops s where s.group_id = v_group_id
    ), '[]'::jsonb),
    'branches', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.name)
      from public.branches b join public.shops s on s.id = b.shop_id where s.group_id = v_group_id
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'user_id', m.user_id, 'role', m.role, 'shop_id', m.shop_id,
        'branch_id', m.branch_id, 'display_name', pr.display_name,
        'email', u.email,
        'created_at', m.created_at
      ) order by m.created_at)
      from public.memberships m
      left join public.profiles pr on pr.id = m.user_id
      left join auth.users u on u.id = m.user_id
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
          select jsonb_agg(jsonb_build_object(
            'id', o.id, 'name', o.name, 'active', o.active, 'sort_order', o.sort_order, 'version', o.version,
            'recipes', coalesce((
              select jsonb_agg(jsonb_build_object('ingredient_id', por.ingredient_id, 'quantity', por.quantity,
                'name', i.name, 'base_unit', i.base_unit))
              from public.product_option_recipes por join public.ingredients i on i.id = por.ingredient_id
              where por.option_id = o.id
            ), '[]'::jsonb)
          ) order by o.sort_order, o.name)
          from public.product_options o where o.product_id = p.id
        ), '[]'::jsonb),
        'recipe', coalesce((
          select jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'quantity', r.quantity,
            'name', i.name, 'base_unit', i.base_unit))
          from public.product_recipes r join public.ingredients i on i.id = r.ingredient_id
          where r.product_id = p.id
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p where p.shop_id in (select id from public.shops where group_id = v_group_id)
    ), '[]'::jsonb),
    'ingredients', coalesce((
      select jsonb_agg(to_jsonb(i) order by i.name)
      from public.ingredients i where i.shop_id in (select id from public.shops where group_id = v_group_id)
    ), '[]'::jsonb),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm where pm.shop_id in (select id from public.shops where group_id = v_group_id)
    ), '[]'::jsonb),
    'settings', coalesce((
      select jsonb_agg(to_jsonb(ss))
      from public.shop_settings ss where ss.shop_id in (select id from public.shops where group_id = v_group_id)
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;
