create or replace function public.update_shop_name(
  p_shop_id uuid,
  p_name text,
  p_version integer default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_current integer;
  v_group_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_manage_shop(p_shop_id) then raise exception 'Shop access denied'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 or char_length(trim(p_name)) > 120 then
    raise exception 'Shop name must be 2 to 120 characters';
  end if;

  select group_id into v_group_id from public.shops where id = p_shop_id;
  if v_group_id is null then raise exception 'Shop not found'; end if;

  select version into v_current from public.shop_settings where shop_id = p_shop_id;
  if p_version is not null and v_current is not null and p_version <> v_current then
    raise exception 'Shop changed; refresh and review';
  end if;

  update public.shops set name = trim(p_name) where id = p_shop_id;
  update public.shop_settings
  set version = version + 1, updated_by = auth.uid(), updated_at = now()
  where shop_id = p_shop_id;

  perform public.bump_shop_config(p_shop_id);

  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, p_shop_id, auth.uid(), 'shop_name_updated', 'shop', p_shop_id,
    jsonb_build_object('name', trim(p_name)));
end;
$$;

revoke all on function public.update_shop_name(uuid, text, integer) from public;
grant execute on function public.update_shop_name(uuid, text, integer) to authenticated;
