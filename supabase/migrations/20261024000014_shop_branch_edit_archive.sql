-- Rename branch, archive/restore shop, archive/restore branch.
-- No delete. All mutations require owner or super_admin role.

-- Rename a branch
create or replace function public.update_branch_name(
  p_branch_id uuid,
  p_name      text
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id  uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select s.id, s.group_id
    into v_shop_id, v_group_id
    from public.branches b
    join public.shops    s on s.id = b.shop_id
   where b.id = p_branch_id;

  if v_shop_id is null then raise exception 'Branch not found'; end if;
  if not public.can_manage_shop(v_shop_id) then raise exception 'Branch access denied'; end if;

  if p_name is null or char_length(trim(p_name)) < 2 or char_length(trim(p_name)) > 120 then
    raise exception 'Branch name must be 2 to 120 characters';
  end if;

  update public.branches set name = trim(p_name) where id = p_branch_id;
  perform public.bump_shop_config(v_shop_id);

  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'branch_name_updated', 'branch', p_branch_id,
    jsonb_build_object('name', trim(p_name)));
end;
$$;

-- Archive or restore a shop (no delete)
create or replace function public.set_shop_active(
  p_shop_id uuid,
  p_active  boolean
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_shop(p_shop_id) then raise exception 'Shop access denied'; end if;

  select group_id into v_group_id from public.shops where id = p_shop_id;
  if v_group_id is null then raise exception 'Shop not found'; end if;

  update public.shops set active = p_active where id = p_shop_id;

  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(),
    case when p_active then 'shop_restored' else 'shop_archived' end,
    'shop', p_shop_id, jsonb_build_object('active', p_active));
end;
$$;

-- Archive or restore a branch (no delete)
create or replace function public.set_branch_active(
  p_branch_id uuid,
  p_active    boolean
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_shop_id  uuid;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select s.id, s.group_id
    into v_shop_id, v_group_id
    from public.branches b
    join public.shops    s on s.id = b.shop_id
   where b.id = p_branch_id;

  if v_shop_id is null then raise exception 'Branch not found'; end if;
  if not public.can_manage_shop(v_shop_id) then raise exception 'Branch access denied'; end if;

  update public.branches set active = p_active where id = p_branch_id;
  perform public.bump_shop_config(v_shop_id);

  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(),
    case when p_active then 'branch_restored' else 'branch_archived' end,
    'branch', p_branch_id, jsonb_build_object('active', p_active));
end;
$$;

revoke all on function public.update_branch_name(uuid, text)   from public;
revoke all on function public.set_shop_active(uuid, boolean)   from public;
revoke all on function public.set_branch_active(uuid, boolean) from public;

grant execute on function public.update_branch_name(uuid, text)   to authenticated;
grant execute on function public.set_shop_active(uuid, boolean)   to authenticated;
grant execute on function public.set_branch_active(uuid, boolean) to authenticated;
