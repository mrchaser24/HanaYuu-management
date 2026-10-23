-- Read-only, permission-scoped query functions. No report aggregates are
-- calculated in the browser and no query returns another shop/branch context.

create or replace function public.get_my_context()
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'profile', (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'memberships', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.created_at)
      from public.memberships m where m.user_id = auth.uid()
    ), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select distinct g.* from public.business_groups g
        join public.memberships m on m.group_id = g.id
        where m.user_id = auth.uid()
      ) x
    ), '[]'::jsonb),
    'shops', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select distinct s.* from public.shops s
        join public.memberships m on m.group_id = s.group_id
        where m.user_id = auth.uid()
          and (
            m.role = 'super_admin'
            or (m.role = 'owner' and m.shop_id = s.id)
            or (m.role = 'staff' and exists (
              select 1 from public.branches b where b.id = m.branch_id and b.shop_id = s.id
            ))
          )
      ) x
    ), '[]'::jsonb),
    'branches', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select distinct b.* from public.branches b
        join public.shops s on s.id = b.shop_id
        join public.memberships m on m.group_id = s.group_id
        where m.user_id = auth.uid()
          and (
            m.role = 'super_admin'
            or (m.role = 'owner' and m.shop_id = s.id)
            or (m.role = 'staff' and m.branch_id = b.id)
          )
      ) x
    ), '[]'::jsonb),
    'devices', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'branch_id', d.branch_id, 'user_id', d.user_id,
        'device_label', d.device_label, 'created_at', d.created_at,
        'last_seen_at', d.last_seen_at, 'revoked_at', d.revoked_at,
        'wipe_requested_at', d.wipe_requested_at
      ) order by d.created_at desc)
      from public.branch_devices d
      where d.user_id = auth.uid() and d.revoked_at is null
    ), '[]'::jsonb)
  ) end;
$$;

create or replace function public.get_branch_catalog(p_branch_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_shop_id uuid;
  v_settings public.shop_settings%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;

  select b.shop_id into v_shop_id
  from public.branches b where b.id = p_branch_id;
  select * into v_settings from public.shop_settings where shop_id = v_shop_id;
  if not found then
    v_settings.tax_inclusive_enabled := false;
    v_settings.tax_rate_bps := 0;
    v_settings.receipt_footer := '';
  end if;

  return jsonb_build_object(
    'branch', (select to_jsonb(b) from public.branches b where b.id = p_branch_id),
    'shop', (select to_jsonb(s) from public.shops s where s.id = v_shop_id),
    'settings', jsonb_build_object(
      'tax_inclusive_enabled', v_settings.tax_inclusive_enabled,
      'tax_rate_bps', v_settings.tax_rate_bps,
      'receipt_footer', v_settings.receipt_footer
    ),
    'payment_methods', coalesce((
      select jsonb_agg(to_jsonb(pm) order by pm.sort_order, pm.name)
      from public.payment_methods pm where pm.shop_id = v_shop_id and pm.active
    ), '[]'::jsonb),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'description', p.description,
        'price_centavos', p.price_centavos, 'flavor_choices', p.flavor_choices,
        'stock_model', p.stock_model, 'active', p.active,
        'expected_yield_quantity', p.expected_yield_quantity,
        'expected_yield_unit', p.expected_yield_unit,
        'pieces', p.pieces, 'rice_included', p.rice_included,
        'branch_available', coalesce(bps.available, true),
        'available', p.active and coalesce(bps.available, true),
        'recipe_complete', exists (select 1 from public.product_recipes r where r.product_id = p.id),
        'stock_quantity', case when p.stock_model = 'batch_produced'
          then coalesce((select f.quantity from public.finished_goods_balances f
            where f.branch_id = p_branch_id and f.product_id = p.id), 0) else null end,
        'stock_available', case when p.stock_model = 'batch_produced'
          then coalesce((select f.quantity from public.finished_goods_balances f
            where f.branch_id = p_branch_id and f.product_id = p.id), 0) >= 1
          else not exists (
            select 1 from public.product_recipes r
            left join public.ingredient_balances ib
              on ib.branch_id = p_branch_id and ib.ingredient_id = r.ingredient_id
            where r.product_id = p.id and coalesce(ib.quantity, 0) < r.quantity
          ) end,
        'options', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', o.id, 'name', o.name, 'sort_order', o.sort_order,
            'cost_centavos', coalesce((
              select round(sum(por.quantity * coalesce(ib.average_cost_centavos, 0)))
              from public.product_option_recipes por
              left join public.ingredient_balances ib
                on ib.branch_id = p_branch_id and ib.ingredient_id = por.ingredient_id
              where por.option_id = o.id
            ), 0)
          ) order by o.sort_order, o.name)
          from public.product_options o where o.product_id = p.id and o.active
        ), '[]'::jsonb)
      ) order by p.name)
      from public.products p
      left join public.branch_product_settings bps
        on bps.branch_id = p_branch_id and bps.product_id = p.id
      where p.shop_id = v_shop_id and p.active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_dashboard_metrics(
  p_scope_type text,
  p_scope_id uuid,
  p_date date default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_branches uuid[];
  v_date date;
  v_from timestamptz;
  v_to timestamptz;
  v_sales bigint := 0;
  v_refunds bigint := 0;
  v_discounts bigint := 0;
  v_cogs bigint := 0;
  v_refund_cost bigint := 0;
  v_expenses bigint := 0;
  v_orders bigint := 0;
  v_cash_sales bigint := 0;
  v_gcash_sales bigint := 0;
  v_cash_refunds bigint := 0;
  v_inventory bigint := 0;
  v_low_stock bigint := 0;
  v_open_shifts bigint := 0;
  v_pending_sync bigint := 0;
  v_pending_approvals bigint := 0;
  v_estimated bigint := 0;
  v_revenue bigint;
  v_gross_profit bigint;
  v_net_profit bigint;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_date := coalesce(p_date, (now() at time zone 'Asia/Manila')::date);
  v_from := (v_date::timestamp) at time zone 'Asia/Manila';
  v_to := ((v_date + 1)::timestamp) at time zone 'Asia/Manila';

  if p_scope_type = 'branch' then
    if not public.can_access_branch(p_scope_id) then raise exception 'Branch access denied'; end if;
    v_branches := array[p_scope_id];
  elsif p_scope_type = 'shop' then
    if not public.can_manage_shop(p_scope_id) then raise exception 'Shop access denied'; end if;
    select array_agg(id) into v_branches from public.branches where shop_id = p_scope_id;
  elsif p_scope_type = 'group' then
    if not public.is_group_member(p_scope_id, array['super_admin']::public.business_role[]) then raise exception 'Group access denied'; end if;
    select array_agg(b.id) into v_branches
    from public.branches b join public.shops s on s.id = b.shop_id where s.group_id = p_scope_id;
  else
    raise exception 'Invalid scope type';
  end if;
  v_branches := coalesce(v_branches, array[]::uuid[]);

  select coalesce(sum(o.total_centavos), 0), coalesce(sum(o.discount_centavos), 0), count(*)
  into v_sales, v_discounts, v_orders
  from public.orders o
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(r.total_centavos), 0), coalesce(sum(r.cost_centavos), 0)
  into v_refunds, v_refund_cost
  from public.order_reversals r join public.orders o on o.id = r.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to;

  select coalesce(sum(ol.cost_snapshot_centavos), 0) into v_cogs
  from public.order_lines ol join public.orders o on o.id = ol.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(e.amount_centavos), 0) into v_expenses
  from public.expenses e
  where e.branch_id = any(v_branches) and e.spent_at >= v_from and e.spent_at < v_to;

  select
    coalesce(sum(case when p.method = 'cash' then p.amount_centavos else 0 end), 0),
    coalesce(sum(case when p.method = 'gcash' then p.amount_centavos else 0 end), 0)
  into v_cash_sales, v_gcash_sales
  from public.payments p join public.orders o on o.id = p.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(r.total_centavos), 0) into v_cash_refunds
  from public.order_reversals r join public.orders o on o.id = r.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and r.refund_method = 'cash';

  select
    coalesce((select sum(ib.quantity * ib.average_cost_centavos) from public.ingredient_balances ib
      where ib.branch_id = any(v_branches)), 0)
    + coalesce((select sum(f.quantity * f.average_cost_centavos) from public.finished_goods_balances f
      where f.branch_id = any(v_branches)), 0)
  into v_inventory;

  select count(*) into v_low_stock
  from public.branches b
  join public.ingredients i on i.shop_id = b.shop_id
  left join public.ingredient_balances ib on ib.branch_id = b.id and ib.ingredient_id = i.id
  where b.id = any(v_branches) and i.active and coalesce(ib.quantity, 0) <= i.low_stock_quantity;

  select count(*) into v_open_shifts from public.cash_shifts
  where branch_id = any(v_branches) and closed_at is null;
  select count(*) into v_pending_sync from public.sync_requests
  where branch_id = any(v_branches) and sync_state in ('pending_sync', 'syncing', 'needs_review');

  select
    (select count(*) from public.cash_movement_requests r join public.cash_shifts s on s.id = r.shift_id
      where s.branch_id = any(v_branches) and r.status = 'pending')
    + (select count(*) from public.order_corrections c where c.branch_id = any(v_branches) and c.status = 'pending')
    + (select count(*) from public.orders o where o.branch_id = any(v_branches) and o.status = 'needs_review')
  into v_pending_approvals;

  select count(distinct o.id) into v_estimated
  from public.orders o join public.order_lines ol on ol.order_id = o.id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and ol.cost_estimated;

  v_revenue := v_sales - v_refunds;
  v_gross_profit := v_revenue - (v_cogs - v_refund_cost);
  v_net_profit := v_gross_profit - v_expenses;

  return jsonb_build_object(
    'business_date', v_date,
    'scope_type', p_scope_type,
    'scope_id', p_scope_id,
    'orders_count', v_orders,
    'gross_sales_centavos', v_sales,
    'refunds_centavos', v_refunds,
    'revenue_centavos', v_revenue,
    'discounts_centavos', v_discounts,
    'cogs_centavos', v_cogs - v_refund_cost,
    'gross_profit_centavos', v_gross_profit,
    'expenses_centavos', v_expenses,
    'net_profit_centavos', v_net_profit,
    'cash_sales_centavos', v_cash_sales - v_cash_refunds,
    'gcash_sales_centavos', v_gcash_sales,
    'inventory_value_centavos', round(v_inventory)::bigint,
    'low_stock_count', v_low_stock,
    'open_shifts_count', v_open_shifts,
    'pending_sync_count', v_pending_sync,
    'pending_approvals_count', v_pending_approvals,
    'estimated_orders_count', v_estimated,
    'is_estimated', v_estimated > 0
  );
end;
$$;

create or replace function public.get_sales_history(
  p_branch_id uuid,
  p_from date default null,
  p_to date default null,
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
  v_limit integer;
  v_offset integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  v_from := coalesce(p_from, (now() at time zone 'Asia/Manila')::date)::timestamp at time zone 'Asia/Manila';
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Manila')::date) + 1)::timestamp at time zone 'Asia/Manila';
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset := greatest(coalesce(p_offset, 0), 0);

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select o.id, o.request_id, o.captured_at, o.created_at, o.offline_captured_at,
             o.status, o.total_centavos, o.subtotal_centavos, o.discount_centavos,
             o.tax_centavos, o.tendered_centavos, o.change_centavos, o.review_reason,
             pr.display_name as cashier_name, pm.name as payment_method_name,
             pm.kind as payment_method_kind,
             (select count(*) from public.order_lines l where l.order_id = o.id) as item_count,
             (select coalesce(jsonb_agg(l.product_name order by l.product_name), '[]'::jsonb)
                from public.order_lines l where l.order_id = o.id) as item_names,
             (select c.status from public.order_corrections c
                where c.order_id = o.id order by c.created_at desc limit 1) as correction_status
      from public.orders o
      left join public.profiles pr on pr.id = o.cashier_id
      left join public.payments pay on pay.order_id = o.id
      left join public.payment_methods pm on pm.id = pay.payment_method_id
      where o.branch_id = p_branch_id and o.created_at >= v_from and o.created_at < v_to
      order by o.created_at desc
      limit v_limit offset v_offset
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_order_detail(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_order from public.orders where id = p_order_id;
  if not found then raise exception 'Order not found'; end if;
  if not public.can_access_branch(v_order.branch_id) then raise exception 'Order access denied'; end if;

  return jsonb_build_object(
    'order', to_jsonb(v_order) || jsonb_build_object(
      'cashier_name', (select display_name from public.profiles where id = v_order.cashier_id),
      'payment_method_name', (select pm.name from public.payment_methods pm where pm.id = v_order.payment_method_id)
    ),
    'lines', coalesce((
      select jsonb_agg(to_jsonb(l) || jsonb_build_object(
        'options', coalesce((
          select jsonb_agg(jsonb_build_object('option_id', olo.option_id, 'name', olo.option_name, 'unit_cost_centavos', olo.unit_cost_centavos)
            order by olo.option_name)
          from public.order_line_options olo where olo.order_line_id = l.id
        ), '[]'::jsonb)
      ) order by l.product_name)
      from public.order_lines l where l.order_id = v_order.id
    ), '[]'::jsonb),
    'payment', (select to_jsonb(p) from public.payments p where p.order_id = v_order.id),
    'corrections', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.created_at desc)
      from public.order_corrections c where c.order_id = v_order.id
    ), '[]'::jsonb),
    'reversal', (select to_jsonb(r) from public.order_reversals r where r.order_id = v_order.id)
  );
end;
$$;

create or replace function public.get_inventory(p_branch_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return jsonb_build_object(
    'ingredients', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select i.id, i.name, i.base_unit, i.category, i.low_stock_quantity, i.active,
               coalesce(ib.quantity, 0) as quantity,
               coalesce(ib.average_cost_centavos, 0) as average_cost_centavos,
               round(coalesce(ib.quantity, 0) * coalesce(ib.average_cost_centavos, 0)) as value_centavos,
               coalesce(ib.quantity, 0) <= i.low_stock_quantity as is_low,
               ib.version
        from public.ingredients i
        left join public.ingredient_balances ib on ib.branch_id = p_branch_id and ib.ingredient_id = i.id
        where i.shop_id = (select shop_id from public.branches where id = p_branch_id)
      ) x
    ), '[]'::jsonb),
    'finished_goods', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select p.id as product_id, p.name, p.stock_model,
               coalesce(f.quantity, 0) as quantity,
               coalesce(f.average_cost_centavos, 0) as average_cost_centavos,
               round(coalesce(f.quantity, 0) * coalesce(f.average_cost_centavos, 0)) as value_centavos,
               f.version
        from public.products p
        left join public.finished_goods_balances f on f.branch_id = p_branch_id and f.product_id = p.id
        where p.shop_id = (select shop_id from public.branches where id = p_branch_id)
          and p.stock_model = 'batch_produced' and p.active
      ) x
    ), '[]'::jsonb),
    'movements', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select m.id, m.kind, m.quantity_delta, m.unit_cost_centavos, m.created_at,
               m.reference_id, i.name as ingredient_name, p.name as product_name,
               pr.display_name as actor_name
        from public.inventory_movements m
        left join public.ingredients i on i.id = m.ingredient_id
        left join public.products p on p.id = m.product_id
        left join public.profiles pr on pr.id = m.created_by
        where m.branch_id = p_branch_id
        order by m.created_at desc limit 100
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_production_batches(p_branch_id uuid, p_limit integer default 50)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select b.id, b.expected_yield, b.actual_yield, b.waste_quantity, b.waste_reason,
             b.total_cost_centavos, b.cost_per_unit_centavos, b.posted_at, b.created_at,
             p.name as product_name, pr.display_name as prepared_by_name
      from public.production_batches b
      join public.products p on p.id = b.product_id
      left join public.profiles pr on pr.id = b.prepared_by
      where b.branch_id = p_branch_id
      order by b.created_at desc
      limit least(greatest(coalesce(p_limit, 50), 1), 200)
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_cash_shifts(p_branch_id uuid, p_limit integer default 50)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.opened_at desc)
    from (
      select s.id, s.branch_id, s.cashier_id, s.opening_cash_centavos, s.opened_at,
             s.closed_at, s.counted_cash_centavos, s.closed_by, s.status, s.note,
             s.expected_cash_centavos, s.over_short_centavos,
             case when s.closed_at is null then public.shift_expected_cash(s.id) else s.expected_cash_centavos end as current_expected_cash_centavos,
             pr.display_name as cashier_name,
             (select coalesce(sum(o.total_centavos), 0) from public.orders o
                join public.payments pay on pay.order_id = o.id
                where o.shift_id = s.id and pay.method = 'cash' and o.status in ('completed', 'refunded', 'voided')) as cash_sales_centavos,
             (select coalesce(sum(cm.amount_centavos), 0) from public.cash_movements cm where cm.shift_id = s.id) as cash_movements_centavos
      from public.cash_shifts s
      left join public.profiles pr on pr.id = s.cashier_id
      where s.branch_id = p_branch_id
      order by s.opened_at desc
      limit least(greatest(coalesce(p_limit, 50), 1), 200)
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_cash_requests(p_branch_id uuid, p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select r.id, r.request_id, r.shift_id, r.kind, r.amount_centavos, r.reason, r.status,
             r.created_at, r.approved_at, r.reviewed_at, r.review_note, r.applied_movement_id,
             pr.display_name as requested_by_name
      from public.cash_movement_requests r
      join public.cash_shifts s on s.id = r.shift_id
      left join public.profiles pr on pr.id = r.requested_by
      where s.branch_id = p_branch_id and (p_status is null or r.status::text = p_status)
      order by r.created_at desc
      limit 200
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_corrections(p_branch_id uuid, p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select c.id, c.order_id, c.kind, c.reason, c.status, c.created_at, c.reviewed_at,
             c.review_note, c.refund_method, c.refund_reference, c.refund_amount_centavos, c.reversal_id,
             o.total_centavos as order_total_centavos,
             pr.display_name as requested_by_name
      from public.order_corrections c
      join public.orders o on o.id = c.order_id
      left join public.profiles pr on pr.id = c.requested_by
      where c.branch_id = p_branch_id and (p_status is null or c.status::text = p_status)
      order by c.created_at desc limit 200
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_expenses(p_branch_id uuid, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_from timestamptz;
  v_to timestamptz;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  v_from := coalesce(p_from, (now() at time zone 'Asia/Manila')::date)::timestamp at time zone 'Asia/Manila';
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Manila')::date) + 1)::timestamp at time zone 'Asia/Manila';
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.spent_at desc)
    from (
      select e.id, e.category, e.description, e.amount_centavos, e.paid_from_cash,
             e.cash_movement_id, e.spent_at, e.created_at, pr.display_name as created_by_name
      from public.expenses e left join public.profiles pr on pr.id = e.created_by
      where e.branch_id = p_branch_id and e.spent_at >= v_from and e.spent_at < v_to
      order by e.spent_at desc limit 200
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_audit_events(p_branch_id uuid, p_limit integer default 100)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.can_access_branch(p_branch_id) then raise exception 'Branch access denied'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
    from (
      select a.id, a.action, a.entity_type, a.entity_id, a.metadata, a.created_at,
             pr.display_name as actor_name
      from public.audit_events a left join public.profiles pr on pr.id = a.actor_id
      where a.branch_id = p_branch_id
      order by a.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.get_reports(
  p_scope_type text,
  p_scope_id uuid,
  p_from date default null,
  p_to date default null
) returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_branches uuid[];
  v_from timestamptz;
  v_to timestamptz;
  v_sales bigint := 0;
  v_refunds bigint := 0;
  v_discounts bigint := 0;
  v_cogs bigint := 0;
  v_refund_cost bigint := 0;
  v_expenses bigint := 0;
  v_orders bigint := 0;
  v_cash bigint := 0;
  v_gcash bigint := 0;
  v_cash_refunds bigint := 0;
  v_estimated bigint := 0;
  v_inventory bigint := 0;
  v_low_stock bigint := 0;
  v_shifts bigint := 0;
  v_expected bigint := 0;
  v_counted bigint := 0;
  v_over_short bigint := 0;
  v_payouts bigint := 0;
  v_drops bigint := 0;
  v_prod_batches bigint := 0;
  v_expected_yield numeric := 0;
  v_actual_yield numeric := 0;
  v_waste numeric := 0;
  v_prod_cost bigint := 0;
  v_corr_requested bigint := 0;
  v_corr_approved bigint := 0;
  v_corr_refunded bigint := 0;
  v_revenue bigint;
  v_gross_profit bigint;
  v_net_profit bigint;
  v_food_cost_bps integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_from := coalesce(p_from, (now() at time zone 'Asia/Manila')::date - 29)::timestamp at time zone 'Asia/Manila';
  v_to := (coalesce(p_to, (now() at time zone 'Asia/Manila')::date) + 1)::timestamp at time zone 'Asia/Manila';

  if p_scope_type = 'branch' then
    if not public.can_manage_branch(p_scope_id) then raise exception 'Branch access denied'; end if;
    v_branches := array[p_scope_id];
  elsif p_scope_type = 'shop' then
    if not public.can_manage_shop(p_scope_id) then raise exception 'Shop access denied'; end if;
    select array_agg(id) into v_branches from public.branches where shop_id = p_scope_id;
  elsif p_scope_type = 'group' then
    if not public.is_group_member(p_scope_id, array['super_admin']::public.business_role[]) then raise exception 'Group access denied'; end if;
    select array_agg(b.id) into v_branches
    from public.branches b join public.shops s on s.id = b.shop_id where s.group_id = p_scope_id;
  else
    raise exception 'Invalid scope type';
  end if;
  v_branches := coalesce(v_branches, array[]::uuid[]);

  select coalesce(sum(o.total_centavos), 0), coalesce(sum(o.discount_centavos), 0), count(*)
  into v_sales, v_discounts, v_orders
  from public.orders o
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(r.total_centavos), 0), coalesce(sum(r.cost_centavos), 0)
  into v_refunds, v_refund_cost
  from public.order_reversals r join public.orders o on o.id = r.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to;

  select coalesce(sum(ol.cost_snapshot_centavos), 0) into v_cogs
  from public.order_lines ol join public.orders o on o.id = ol.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(e.amount_centavos), 0) into v_expenses
  from public.expenses e where e.branch_id = any(v_branches) and e.spent_at >= v_from and e.spent_at < v_to;

  select
    coalesce(sum(case when pay.method = 'cash' then pay.amount_centavos else 0 end), 0),
    coalesce(sum(case when pay.method = 'gcash' then pay.amount_centavos else 0 end), 0)
  into v_cash, v_gcash
  from public.payments pay join public.orders o on o.id = pay.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and o.status in ('completed', 'refunded', 'voided');

  select coalesce(sum(r.total_centavos), 0) into v_cash_refunds
  from public.order_reversals r join public.orders o on o.id = r.order_id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
    and r.refund_method = 'cash';

  select count(distinct o.id) into v_estimated
  from public.orders o join public.order_lines ol on ol.order_id = o.id
  where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to and ol.cost_estimated;

  select
    coalesce((select sum(ib.quantity * ib.average_cost_centavos) from public.ingredient_balances ib where ib.branch_id = any(v_branches)), 0)
    + coalesce((select sum(f.quantity * f.average_cost_centavos) from public.finished_goods_balances f where f.branch_id = any(v_branches)), 0)
  into v_inventory;

  select count(*) into v_low_stock
  from public.branches b join public.ingredients i on i.shop_id = b.shop_id
  left join public.ingredient_balances ib on ib.branch_id = b.id and ib.ingredient_id = i.id
  where b.id = any(v_branches) and i.active and coalesce(ib.quantity, 0) <= i.low_stock_quantity;

  select count(*), coalesce(sum(expected_cash_centavos), 0), coalesce(sum(counted_cash_centavos), 0), coalesce(sum(over_short_centavos), 0)
  into v_shifts, v_expected, v_counted, v_over_short
  from public.cash_shifts
  where branch_id = any(v_branches) and opened_at >= v_from and opened_at < v_to;

  select
    coalesce(sum(case when kind = 'payout' then amount_centavos else 0 end), 0),
    coalesce(sum(case when kind = 'safe_drop' then amount_centavos else 0 end), 0)
  into v_payouts, v_drops
  from public.cash_movements where shift_id in (
    select id from public.cash_shifts where branch_id = any(v_branches) and opened_at >= v_from and opened_at < v_to
  );

  select count(*), coalesce(sum(expected_yield), 0), coalesce(sum(actual_yield), 0),
         coalesce(sum(waste_quantity), 0), coalesce(sum(total_cost_centavos), 0)
  into v_prod_batches, v_expected_yield, v_actual_yield, v_waste, v_prod_cost
  from public.production_batches
  where branch_id = any(v_branches) and created_at >= v_from and created_at < v_to;

  select count(*), coalesce(sum(case when status = 'approved' then 1 else 0 end), 0),
         coalesce(sum(case when status = 'approved' then refund_amount_centavos else 0 end), 0)
  into v_corr_requested, v_corr_approved, v_corr_refunded
  from public.order_corrections
  where branch_id = any(v_branches) and created_at >= v_from and created_at < v_to;

  v_revenue := v_sales - v_refunds;
  v_gross_profit := v_revenue - (v_cogs - v_refund_cost);
  v_net_profit := v_gross_profit - v_expenses;
  if v_revenue > 0 then
    v_food_cost_bps := round((v_cogs - v_refund_cost)::numeric * 10000 / v_revenue)::integer;
  else
    v_food_cost_bps := 0;
  end if;

  return jsonb_build_object(
    'from_date', v_from at time zone 'Asia/Manila',
    'to_date', v_to at time zone 'Asia/Manila',
    'scope_type', p_scope_type,
    'scope_id', p_scope_id,
    'sales', jsonb_build_object(
      'orders_count', v_orders, 'gross_sales_centavos', v_sales, 'refunds_centavos', v_refunds,
      'revenue_centavos', v_revenue, 'discounts_centavos', v_discounts,
      'cash_net_centavos', v_cash - v_cash_refunds, 'gcash_centavos', v_gcash,
      'estimated_orders_count', v_estimated
    ),
    'profit', jsonb_build_object(
      'cogs_centavos', v_cogs - v_refund_cost, 'gross_profit_centavos', v_gross_profit,
      'expenses_centavos', v_expenses, 'net_profit_centavos', v_net_profit,
      'food_cost_bps', v_food_cost_bps, 'is_estimated', v_estimated > 0
    ),
    'inventory', jsonb_build_object('value_centavos', round(v_inventory)::bigint, 'low_stock_count', v_low_stock),
    'cash', jsonb_build_object(
      'shifts_count', v_shifts, 'expected_cash_centavos', v_expected,
      'counted_cash_centavos', v_counted, 'over_short_centavos', v_over_short,
      'payouts_centavos', v_payouts, 'safe_drops_centavos', v_drops, 'cash_refunds_centavos', v_cash_refunds
    ),
    'production', jsonb_build_object(
      'batches_count', v_prod_batches, 'expected_yield', v_expected_yield,
      'actual_yield', v_actual_yield, 'waste_quantity', v_waste, 'total_cost_centavos', v_prod_cost
    ),
    'corrections', jsonb_build_object(
      'requested_count', v_corr_requested, 'approved_count', v_corr_approved,
      'refunded_centavos', v_corr_refunded
    ),
    'popular_products', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.quantity desc)
      from (
        select ol.product_name, sum(ol.quantity)::bigint as quantity,
               sum(ol.line_subtotal_centavos)::bigint as sales_centavos
        from public.order_lines ol join public.orders o on o.id = ol.order_id
        where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
          and o.status in ('completed', 'refunded', 'voided')
        group by ol.product_name order by sum(ol.quantity) desc limit 10
      ) x
    ), '[]'::jsonb),
    'popular_options', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.quantity desc)
      from (
        select olo.option_name, sum(ol.quantity)::bigint as quantity
        from public.order_line_options olo
        join public.order_lines ol on ol.id = olo.order_line_id
        join public.orders o on o.id = ol.order_id
        where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
          and o.status in ('completed', 'refunded', 'voided')
        group by olo.option_name order by sum(ol.quantity) desc limit 10
      ) x
    ), '[]'::jsonb),
    'cashiers', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sales_centavos desc)
      from (
        select pr.display_name as cashier_name, count(distinct o.id)::bigint as orders_count,
               coalesce(sum(o.total_centavos), 0)::bigint as sales_centavos
        from public.orders o left join public.profiles pr on pr.id = o.cashier_id
        where o.branch_id = any(v_branches) and o.created_at >= v_from and o.created_at < v_to
          and o.status in ('completed', 'refunded', 'voided')
        group by pr.display_name
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_my_context() from public;
revoke all on function public.get_branch_catalog(uuid) from public;
revoke all on function public.get_dashboard_metrics(text, uuid, date) from public;
revoke all on function public.get_sales_history(uuid, date, date, integer, integer) from public;
revoke all on function public.get_order_detail(uuid) from public;
revoke all on function public.get_inventory(uuid) from public;
revoke all on function public.get_production_batches(uuid, integer) from public;
revoke all on function public.get_cash_shifts(uuid, integer) from public;
revoke all on function public.get_cash_requests(uuid, text) from public;
revoke all on function public.get_corrections(uuid, text) from public;
revoke all on function public.get_expenses(uuid, date, date) from public;
revoke all on function public.get_audit_events(uuid, integer) from public;
revoke all on function public.get_reports(text, uuid, date, date) from public;

grant execute on function public.get_my_context() to authenticated;
grant execute on function public.get_branch_catalog(uuid) to authenticated;
grant execute on function public.get_dashboard_metrics(text, uuid, date) to authenticated;
grant execute on function public.get_sales_history(uuid, date, date, integer, integer) to authenticated;
grant execute on function public.get_order_detail(uuid) to authenticated;
grant execute on function public.get_inventory(uuid) to authenticated;
grant execute on function public.get_production_batches(uuid, integer) to authenticated;
grant execute on function public.get_cash_shifts(uuid, integer) to authenticated;
grant execute on function public.get_cash_requests(uuid, text) to authenticated;
grant execute on function public.get_corrections(uuid, text) to authenticated;
grant execute on function public.get_expenses(uuid, date, date) to authenticated;
grant execute on function public.get_audit_events(uuid, integer) to authenticated;
grant execute on function public.get_reports(text, uuid, date, date) to authenticated;
