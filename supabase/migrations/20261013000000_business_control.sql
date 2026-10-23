create extension if not exists pgcrypto;

create type public.business_role as enum ('super_admin', 'owner', 'staff');
create type public.stock_model as enum ('made_to_order', 'batch_produced');
create type public.order_status as enum ('pending_sync', 'completed', 'needs_review', 'voided', 'refunded', 'rejected');
create type public.payment_kind as enum ('cash', 'gcash');
create type public.movement_kind as enum ('restock', 'production_consumption', 'production_output', 'sale_consumption', 'reversal', 'adjustment');
create type public.request_status as enum ('pending', 'approved', 'rejected');
 
create table public.business_groups (
  id uuid primary key default gen_random_uuid(), name text not null check (char_length(trim(name)) between 2 and 120), created_at timestamptz not null default now()
);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade, display_name text not null check (char_length(trim(display_name)) between 2 and 100), created_at timestamptz not null default now()
);
create table public.shops (
  id uuid primary key default gen_random_uuid(), group_id uuid not null references public.business_groups(id) on delete cascade, name text not null, timezone text not null default 'Asia/Manila', created_at timestamptz not null default now(), unique(group_id, name)
);
create table public.branches (
  id uuid primary key default gen_random_uuid(), shop_id uuid not null references public.shops(id) on delete cascade, name text not null, created_at timestamptz not null default now(), unique(shop_id, name)
);
create table public.memberships (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade, group_id uuid not null references public.business_groups(id) on delete cascade, shop_id uuid references public.shops(id) on delete cascade, branch_id uuid references public.branches(id) on delete cascade, role public.business_role not null, created_at timestamptz not null default now(),
  check ((role = 'super_admin' and shop_id is null and branch_id is null) or (role = 'owner' and shop_id is not null and branch_id is null) or (role = 'staff' and branch_id is not null))
);
create unique index memberships_scope_unique on public.memberships(user_id, group_id, role, coalesce(shop_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid));
create table public.branch_devices (
  id uuid primary key default gen_random_uuid(), branch_id uuid not null references public.branches(id) on delete cascade, user_id uuid not null references auth.users(id) on delete cascade, device_label text not null, device_key_hash text not null unique, revoked_at timestamptz, created_at timestamptz not null default now()
);
create table public.products (
  id uuid primary key default gen_random_uuid(), shop_id uuid not null references public.shops(id) on delete cascade, name text not null, description text not null default '', price_centavos integer not null check (price_centavos >= 0), flavor_choices smallint not null default 0 check (flavor_choices >= 0 and flavor_choices <= 10), stock_model public.stock_model not null default 'made_to_order', active boolean not null default true, version integer not null default 1, created_at timestamptz not null default now(), unique(shop_id, name)
);
create table public.product_options (
  id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete cascade, name text not null, active boolean not null default true, unique(product_id, name)
);
create table public.ingredients (
  id uuid primary key default gen_random_uuid(), shop_id uuid not null references public.shops(id) on delete cascade, name text not null, base_unit text not null check (base_unit in ('g','ml','piece')), low_stock_quantity numeric(14,3) not null default 0 check (low_stock_quantity >= 0), active boolean not null default true, unique(shop_id, name)
);
create table public.product_recipes (
  id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete cascade, ingredient_id uuid not null references public.ingredients(id) on delete restrict, quantity numeric(14,3) not null check (quantity > 0), unique(product_id, ingredient_id)
);
create table public.ingredient_balances (
  branch_id uuid not null references public.branches(id) on delete cascade, ingredient_id uuid not null references public.ingredients(id) on delete cascade, quantity numeric(14,3) not null default 0 check (quantity >= 0), average_cost_centavos numeric(18,6) not null default 0 check (average_cost_centavos >= 0), version integer not null default 1, primary key(branch_id, ingredient_id)
);
create table public.finished_goods_balances (
  branch_id uuid not null references public.branches(id) on delete cascade, product_id uuid not null references public.products(id) on delete cascade, quantity numeric(14,3) not null default 0 check (quantity >= 0), average_cost_centavos numeric(18,6) not null default 0 check (average_cost_centavos >= 0), version integer not null default 1, primary key(branch_id, product_id)
);
create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(), branch_id uuid not null references public.branches(id), ingredient_id uuid references public.ingredients(id), product_id uuid references public.products(id), kind public.movement_kind not null, quantity_delta numeric(14,3) not null check (quantity_delta <> 0), unit_cost_centavos numeric(18,6) not null default 0, reference_id uuid, created_by uuid not null references auth.users(id), created_at timestamptz not null default now(), check ((ingredient_id is null) <> (product_id is null))
);
create table public.orders (
  id uuid primary key default gen_random_uuid(), branch_id uuid not null references public.branches(id), cashier_id uuid not null references auth.users(id), device_id uuid references public.branch_devices(id), request_id uuid not null, status public.order_status not null default 'completed', total_centavos integer not null check (total_centavos >= 0), captured_at timestamptz not null default now(), created_at timestamptz not null default now(), unique(device_id, request_id)
);
create table public.order_lines (
  id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade, product_id uuid not null references public.products(id), product_name text not null, unit_price_centavos integer not null, quantity integer not null check (quantity > 0), cost_snapshot_centavos integer not null default 0, selected_options jsonb not null default '[]'::jsonb
);
create table public.payments (
  id uuid primary key default gen_random_uuid(), order_id uuid not null unique references public.orders(id) on delete cascade, method public.payment_kind not null, amount_centavos integer not null check(amount_centavos >= 0), reference text, created_at timestamptz not null default now()
);
create table public.cash_shifts (
  id uuid primary key default gen_random_uuid(), branch_id uuid not null references public.branches(id), cashier_id uuid not null references auth.users(id), opening_cash_centavos integer not null default 0 check(opening_cash_centavos >= 0), opened_at timestamptz not null default now(), closed_at timestamptz, counted_cash_centavos integer check(counted_cash_centavos >= 0)
);
create table public.cash_movement_requests (
  id uuid primary key default gen_random_uuid(), shift_id uuid not null references public.cash_shifts(id), requested_by uuid not null references auth.users(id), kind text not null check(kind in ('payout','safe_drop')), amount_centavos integer not null check(amount_centavos > 0), reason text not null check(char_length(trim(reason)) >= 3), status public.request_status not null default 'pending', approved_by uuid references auth.users(id), approved_at timestamptz, created_at timestamptz not null default now()
);
create table public.sync_requests (
  id uuid primary key default gen_random_uuid(), device_id uuid not null references public.branch_devices(id), request_id uuid not null, action_type text not null, status public.order_status not null default 'pending_sync', captured_at timestamptz not null, server_result jsonb, created_at timestamptz not null default now(), unique(device_id, request_id)
);
create table public.audit_events (
  id bigint generated always as identity primary key, group_id uuid not null references public.business_groups(id), actor_id uuid references auth.users(id), action text not null, entity_type text not null, entity_id uuid, metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create index orders_branch_captured_idx on public.orders(branch_id, captured_at desc);
create index inventory_movements_branch_created_idx on public.inventory_movements(branch_id, created_at desc);
create index cash_movement_requests_shift_status_idx on public.cash_movement_requests(shift_id, status);

create or replace function public.is_group_member(target_group uuid, allowed_roles public.business_role[] default array['super_admin','owner','staff']::public.business_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.memberships m where m.user_id = auth.uid() and m.group_id = target_group and m.role = any(allowed_roles));
$$;
create or replace function public.can_access_branch(target_branch uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.memberships m join public.branches b on b.id = target_branch join public.shops s on s.id = b.shop_id where m.user_id = auth.uid() and m.group_id = s.group_id and (m.role = 'super_admin' or (m.role = 'owner' and m.shop_id = s.id) or (m.role = 'staff' and m.branch_id = target_branch)));
$$;

alter table public.business_groups enable row level security; alter table public.shops enable row level security; alter table public.branches enable row level security; alter table public.memberships enable row level security; alter table public.products enable row level security; alter table public.product_options enable row level security; alter table public.ingredients enable row level security; alter table public.product_recipes enable row level security; alter table public.ingredient_balances enable row level security; alter table public.finished_goods_balances enable row level security; alter table public.inventory_movements enable row level security; alter table public.orders enable row level security; alter table public.order_lines enable row level security; alter table public.payments enable row level security; alter table public.cash_shifts enable row level security; alter table public.cash_movement_requests enable row level security; alter table public.branch_devices enable row level security; alter table public.sync_requests enable row level security; alter table public.audit_events enable row level security;

create policy "members see groups" on public.business_groups for select using (public.is_group_member(id));
create policy "members see shops" on public.shops for select using (public.is_group_member(group_id));
create policy "members see branches" on public.branches for select using (public.can_access_branch(id));
create policy "members see products" on public.products for select using (public.is_group_member((select group_id from public.shops where id = shop_id)));
create policy "members see ingredients" on public.ingredients for select using (public.is_group_member((select group_id from public.shops where id = shop_id)));
create policy "branch members see ingredient balances" on public.ingredient_balances for select using (public.can_access_branch(branch_id));
create policy "branch members see finished balances" on public.finished_goods_balances for select using (public.can_access_branch(branch_id));
create policy "branch members see orders" on public.orders for select using (public.can_access_branch(branch_id));
create policy "branch members see shifts" on public.cash_shifts for select using (public.can_access_branch(branch_id));
create policy "branch members see cash movement requests" on public.cash_movement_requests for select using (public.can_access_branch((select branch_id from public.cash_shifts where id = shift_id)));

revoke all on all tables in schema public from anon;

create or replace function public.seed_chicken_wings(target_shop uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.shops where id = target_shop) then raise exception 'Unknown shop'; end if;
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

comment on function public.seed_chicken_wings(uuid) is 'Seeds the supplied chicken-wings catalogue. Invoke after creating a shop.';
