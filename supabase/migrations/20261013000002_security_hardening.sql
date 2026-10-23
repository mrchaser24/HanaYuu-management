-- Harden permissions: clients read scope-filtered data, while all financial writes use RPCs.
alter table public.profiles enable row level security;

create policy "users read own profile" on public.profiles for select using (id = auth.uid());
create policy "users update own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "users create own profile" on public.profiles for insert with check (id = auth.uid());
create policy "members see memberships in group" on public.memberships for select using (public.is_group_member(group_id));
create policy "members see product options" on public.product_options for select using (public.is_group_member((select s.group_id from public.products p join public.shops s on s.id = p.shop_id where p.id = product_id)));
create policy "members see recipes" on public.product_recipes for select using (public.is_group_member((select s.group_id from public.products p join public.shops s on s.id = p.shop_id where p.id = product_id)));
create policy "branch members see inventory ledger" on public.inventory_movements for select using (public.can_access_branch(branch_id));
create policy "branch members see lines" on public.order_lines for select using (public.can_access_branch((select branch_id from public.orders where id = order_id)));
create policy "branch members see payments" on public.payments for select using (public.can_access_branch((select branch_id from public.orders where id = order_id)));
create policy "members see devices in permitted branches" on public.branch_devices for select using (public.can_access_branch(branch_id));
create policy "members see sync status in permitted branch" on public.sync_requests for select using (public.can_access_branch((select branch_id from public.branch_devices where id = device_id)));
create policy "members see audit in group" on public.audit_events for select using (public.is_group_member(group_id));

revoke all on all tables in schema public from authenticated;
grant select on public.business_groups, public.shops, public.branches, public.memberships, public.products, public.product_options, public.ingredients, public.product_recipes, public.ingredient_balances, public.finished_goods_balances, public.inventory_movements, public.orders, public.order_lines, public.payments, public.cash_shifts, public.cash_movement_requests, public.branch_devices, public.sync_requests, public.audit_events to authenticated;
grant select, insert, update on public.profiles to authenticated;

revoke all on function public.is_group_member(uuid, public.business_role[]) from public;
revoke all on function public.can_access_branch(uuid) from public;
revoke all on function public.seed_chicken_wings(uuid) from public;

create or replace function public.seed_chicken_wings(target_shop uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_group_id uuid;
begin
  select group_id into v_group_id from public.shops where id = target_shop;
  if v_group_id is null or not public.is_group_member(v_group_id, array['super_admin','owner']::public.business_role[]) then
    raise exception 'Shop configuration access denied';
  end if;
  insert into public.products (shop_id, name, description, price_centavos, flavor_choices, stock_model)
  values
    (target_shop, 'Solo 2-piece meal', '2 wings + 1 Java rice', 8900, 1, 'made_to_order'),
    (target_shop, 'Solo 3-piece meal', '3 wings + 1 Java rice', 11900, 1, 'made_to_order'),
    (target_shop, '6-piece wings', '6 wingette/drummette', 18900, 2, 'made_to_order'),
    (target_shop, '12-piece wings', '12 wingette/drummette', 34900, 3, 'made_to_order'),
    (target_shop, '20-piece wings', '20 wingette/drummette', 54900, 4, 'made_to_order'),
    (target_shop, '30-piece wings', '30 wingette/drummette', 79900, 5, 'made_to_order')
  on conflict (shop_id, name) do nothing;
end;
$$;
grant execute on function public.seed_chicken_wings(uuid) to authenticated;
