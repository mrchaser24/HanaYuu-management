-- Delete a product option (flavor) by id. Requires shop management access.
create or replace function public.delete_product_option(
  p_product_id uuid,
  p_option_id uuid
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
  if v_shop_id is null or not public.can_manage_shop(v_shop_id) then raise exception 'Option configuration access denied'; end if;
  delete from public.product_options where id = p_option_id and product_id = p_product_id;
  perform public.bump_shop_config(v_shop_id);
  insert into public.audit_events (group_id, shop_id, actor_id, action, entity_type, entity_id, metadata)
  values (v_group_id, v_shop_id, auth.uid(), 'option_deleted', 'product_option', p_option_id,
    jsonb_build_object('product_id', p_product_id));
end;
$$;

revoke all on function public.delete_product_option(uuid, uuid) from public;
grant execute on function public.delete_product_option(uuid, uuid) to authenticated;
