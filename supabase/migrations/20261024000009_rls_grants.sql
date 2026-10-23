-- RLS and least-privilege grants for operational tables. All writes remain
-- RPC-only; clients may read only data scoped to their branch/shop/group.

alter table public.shop_settings enable row level security;
alter table public.payment_methods enable row level security;
alter table public.branch_product_settings enable row level security;
alter table public.product_option_recipes enable row level security;
alter table public.restocks enable row level security;
alter table public.restock_items enable row level security;
alter table public.production_batches enable row level security;
alter table public.production_batch_inputs enable row level security;
alter table public.order_line_consumptions enable row level security;
alter table public.order_line_options enable row level security;
alter table public.cash_movements enable row level security;
alter table public.order_corrections enable row level security;
alter table public.order_reversals enable row level security;
alter table public.expenses enable row level security;

drop policy if exists "members see shop settings" on public.shop_settings;
create policy "members see shop settings" on public.shop_settings for select
  using (public.can_access_shop(shop_id));

drop policy if exists "members see payment methods" on public.payment_methods;
create policy "members see payment methods" on public.payment_methods for select
  using (public.can_access_shop(shop_id));

drop policy if exists "branch members see product availability" on public.branch_product_settings;
create policy "branch members see product availability" on public.branch_product_settings for select
  using (public.can_access_branch(branch_id));

drop policy if exists "members see option recipes" on public.product_option_recipes;
create policy "members see option recipes" on public.product_option_recipes for select
  using (public.is_group_member((
    select s.group_id
    from public.product_options o
    join public.products p on p.id = o.product_id
    join public.shops s on s.id = p.shop_id
    where o.id = option_id
  )));

drop policy if exists "branch members see restocks" on public.restocks;
create policy "branch members see restocks" on public.restocks for select
  using (public.can_access_branch(branch_id));

drop policy if exists "branch members see restock items" on public.restock_items;
create policy "branch members see restock items" on public.restock_items for select
  using (exists (
    select 1 from public.restocks r where r.id = restock_id and public.can_access_branch(r.branch_id)
  ));

drop policy if exists "branch members see production batches" on public.production_batches;
create policy "branch members see production batches" on public.production_batches for select
  using (public.can_access_branch(branch_id));

drop policy if exists "branch members see production inputs" on public.production_batch_inputs;
create policy "branch members see production inputs" on public.production_batch_inputs for select
  using (exists (
    select 1 from public.production_batches pb where pb.id = batch_id and public.can_access_branch(pb.branch_id)
  ));

drop policy if exists "branch members see line consumption" on public.order_line_consumptions;
create policy "branch members see line consumption" on public.order_line_consumptions for select
  using (exists (
    select 1 from public.order_lines ol join public.orders o on o.id = ol.order_id
    where ol.id = order_line_id and public.can_access_branch(o.branch_id)
  ));

drop policy if exists "branch members see line options" on public.order_line_options;
create policy "branch members see line options" on public.order_line_options for select
  using (exists (
    select 1 from public.order_lines ol join public.orders o on o.id = ol.order_id
    where ol.id = order_line_id and public.can_access_branch(o.branch_id)
  ));

drop policy if exists "branch members see applied cash movements" on public.cash_movements;
create policy "branch members see applied cash movements" on public.cash_movements for select
  using (exists (
    select 1 from public.cash_shifts s where s.id = shift_id and public.can_access_branch(s.branch_id)
  ));

drop policy if exists "branch members see corrections" on public.order_corrections;
create policy "branch members see corrections" on public.order_corrections for select
  using (public.can_access_branch(branch_id));

drop policy if exists "branch members see reversals" on public.order_reversals;
create policy "branch members see reversals" on public.order_reversals for select
  using (public.can_access_branch(branch_id));

drop policy if exists "branch members see expenses" on public.expenses;
create policy "branch members see expenses" on public.expenses for select
  using (public.can_access_branch(branch_id));

revoke all on table
  public.shop_settings, public.payment_methods, public.branch_product_settings,
  public.product_option_recipes, public.restocks, public.restock_items,
  public.production_batches, public.production_batch_inputs,
  public.order_line_consumptions, public.order_line_options,
  public.cash_movements, public.order_corrections, public.order_reversals,
  public.expenses
from anon, authenticated;

grant select on table
  public.shop_settings, public.payment_methods, public.branch_product_settings,
  public.product_option_recipes, public.restocks, public.restock_items,
  public.production_batches, public.production_batch_inputs,
  public.order_line_consumptions, public.order_line_options,
  public.cash_movements, public.order_corrections, public.order_reversals,
  public.expenses
to authenticated;

-- Never expose stored device-key hashes through PostgREST.
revoke all on table public.branch_devices from anon, authenticated;
grant select (
  id, branch_id, user_id, device_label, revoked_at, created_at,
  last_seen_at, wipe_requested_at, revoked_by, revoked_reason, version
) on public.branch_devices to authenticated;

-- These helpers are referenced by RLS policies, so signed-in clients need
-- EXECUTE even though they only return scope booleans.
grant execute on function public.is_group_member(uuid, public.business_role[]) to authenticated;
grant execute on function public.can_access_branch(uuid) to authenticated;
grant execute on function public.can_access_shop(uuid) to authenticated;
grant execute on function public.can_manage_shop(uuid) to authenticated;
grant execute on function public.can_manage_branch(uuid) to authenticated;
