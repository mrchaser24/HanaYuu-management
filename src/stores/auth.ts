import { computed, ref, watch } from 'vue'
import { defineStore } from 'pinia'
import type { Session } from '@supabase/supabase-js'
import { supabase, isSupabaseConfigured } from '../lib/supabase'
import { ApiError, ensureProfile, getMyContext } from '../lib/api'
import type { Branch, BusinessGroup, ContextResponse, Device, Membership, Profile, Role, Shop } from '../lib/types'

const EMPTY_CONTEXT: ContextResponse = {
  profile: null,
  memberships: [],
  groups: [],
  shops: [],
  branches: [],
  devices: [],
}

function contextKey(userId: string) {
  return `benta.context.${userId}`
}

function branchKey(userId: string) {
  return `benta.branch.${userId}`
}

function highestRole(memberships: Membership[]): Role | null {
  if (memberships.some((membership) => membership.role === 'super_admin')) return 'super_admin'
  if (memberships.some((membership) => membership.role === 'owner')) return 'owner'
  if (memberships.some((membership) => membership.role === 'staff')) return 'staff'
  return null
}

function readCachedContext(userId: string): ContextResponse | null {
  try {
    const raw = localStorage.getItem(contextKey(userId))
    if (!raw) return null
    return JSON.parse(raw) as ContextResponse
  } catch {
    return null
  }
}

function writeCachedContext(userId: string, context: ContextResponse) {
  try {
    localStorage.setItem(contextKey(userId), JSON.stringify(context))
  } catch {
    return
  }
}

export const useAuthStore = defineStore('auth', () => {
  const session = ref<Session | null>(null)
  const context = ref<ContextResponse>({ ...EMPTY_CONTEXT })
  const activeBranchId = ref<string | null>(null)
  const activeGroupId = ref<string | null>(null)
  const initialized = ref(false)
  const loadingContext = ref(false)
  const authError = ref<string | null>(null)
  const contextError = ref<string | null>(null)
  const usingCachedContext = ref(false)

  let initPromise: Promise<void> | null = null
  let unsubscribe: (() => void) | null = null

  const user = computed(() => session.value?.user ?? null)
  const profile = computed<Profile | null>(() => context.value.profile)
  const memberships = computed(() => context.value.memberships)
  const groups = computed<BusinessGroup[]>(() => context.value.groups)
  const shops = computed<Shop[]>(() => context.value.shops)
  const branches = computed<Branch[]>(() => context.value.branches)
  const devices = computed<Device[]>(() => context.value.devices)
  const isAuthenticated = computed(() => Boolean(session.value?.user))
  const role = computed<Role | null>(() => highestRole(memberships.value))
  const isSuperAdmin = computed(() => role.value === 'super_admin')
  const isOwner = computed(() => role.value === 'owner' || isSuperAdmin.value)
  const displayName = computed(() => profile.value?.display_name || user.value?.email?.split('@')[0] || 'Team member')
  const email = computed(() => user.value?.email ?? '')

  const activeBranch = computed<Branch | null>(
    () => branches.value.find((branch) => branch.id === activeBranchId.value) ?? null,
  )
  const activeShop = computed<Shop | null>(() => {
    if (!activeBranch.value) return shops.value[0] ?? null
    return shops.value.find((shop) => shop.id === activeBranch.value?.shop_id) ?? null
  })
  const activeGroup = computed<BusinessGroup | null>(() => {
    if (activeGroupId.value) {
      return groups.value.find((group) => group.id === activeGroupId.value) ?? null
    }
    if (activeShop.value) return groups.value.find((group) => group.id === activeShop.value?.group_id) ?? null
    return groups.value[0] ?? null
  })
  const activeShopId = computed(() => activeShop.value?.id ?? null)
  const activeGroupIdValue = computed(() => activeGroup.value?.id ?? null)

  const canManageShop = computed(() => {
    if (!activeShopId.value || !role.value) return false
    return role.value === 'super_admin' || role.value === 'owner'
  })
  const canManageBranch = computed(() => {
    if (!activeBranchId.value || !role.value) return false
    return role.value === 'super_admin' || role.value === 'owner'
  })
  const canViewReports = computed(() => canManageBranch.value)

  const branchesForRole = computed(() => {
    if (role.value === 'staff') {
      const ids = new Set(
        memberships.value.filter((membership) => membership.role === 'staff').map((membership) => membership.branch_id),
      )
      return branches.value.filter((branch) => ids.has(branch.id))
    }
    return branches.value
  })

  function applyContext(next: ContextResponse) {
    context.value = {
      ...EMPTY_CONTEXT,
      ...next,
      profile: next.profile,
      memberships: next.memberships ?? [],
      groups: next.groups ?? [],
      shops: next.shops ?? [],
      branches: next.branches ?? [],
      devices: next.devices ?? [],
    }
    const storedBranch = user.value ? localStorage.getItem(branchKey(user.value.id)) : null
    const available = branches.value
    if (!activeBranchId.value || !available.some((branch) => branch.id === activeBranchId.value)) {
      activeBranchId.value =
        storedBranch && available.some((branch) => branch.id === storedBranch)
          ? storedBranch
          : available[0]?.id ?? null
    }
    if (!groups.value.some((group) => group.id === activeGroupId.value)) {
      activeGroupId.value = groups.value[0]?.id ?? null
    }
  }

  async function loadContext() {
    if (!user.value) return
    if (!supabase) throw new ApiError('Supabase is not configured.')
    loadingContext.value = true
    contextError.value = null
    try {
      let next = await getMyContext()
      usingCachedContext.value = false
      if (!next.profile) {
        const fallbackName = (user.value.email?.split('@')[0] ?? 'Team member').replace(/[._-]+/g, ' ').trim()
        await ensureProfile(fallbackName.length >= 2 ? fallbackName : 'Team member')
        next = await getMyContext()
      }
      applyContext(next)
      writeCachedContext(user.value.id, next)
    } catch (error) {
      const cached = readCachedContext(user.value.id)
      if (cached) {
        applyContext(cached)
        usingCachedContext.value = true
        contextError.value = error instanceof Error ? `${error.message} Showing your last saved access.` : String(error)
      } else {
        contextError.value = error instanceof Error ? error.message : String(error)
        throw error
      }
    } finally {
      loadingContext.value = false
    }
  }

  async function refreshContext() {
    await loadContext()
  }

  function setBranch(branchId: string) {
    if (!branches.value.some((branch) => branch.id === branchId)) return
    activeBranchId.value = branchId
    if (user.value) localStorage.setItem(branchKey(user.value.id), branchId)
    const branch = branches.value.find((item) => item.id === branchId)
    const shop = shops.value.find((item) => item.id === branch?.shop_id)
    if (shop) activeGroupId.value = shop.group_id
  }

  function setGroup(groupId: string) {
    if (!groups.value.some((group) => group.id === groupId)) return
    activeGroupId.value = groupId
    const groupShopIds = new Set(shops.value.filter((shop) => shop.group_id === groupId).map((shop) => shop.id))
    const currentBranch = activeBranch.value
    if (!currentBranch || !groupShopIds.has(currentBranch.shop_id)) {
      const nextBranch = branches.value.find((branch) => groupShopIds.has(branch.shop_id))
      if (nextBranch) setBranch(nextBranch.id)
    }
  }

  function clearSessionState() {
    session.value = null
    context.value = { ...EMPTY_CONTEXT }
    activeBranchId.value = null
    activeGroupId.value = null
    authError.value = null
    contextError.value = null
    usingCachedContext.value = false
  }

  async function signIn(emailAddress: string, password: string) {
    if (!supabase) throw new ApiError('Supabase is not configured.')
    authError.value = null
    const { data, error } = await supabase.auth.signInWithPassword({ email: emailAddress.trim(), password })
    if (error) {
      authError.value = error.message
      throw new ApiError(error.message)
    }
    session.value = data.session
    await loadContext()
  }

  async function signOut() {
    if (supabase) await supabase.auth.signOut()
    clearSessionState()
  }

  async function init() {
    if (initPromise) return initPromise
    initPromise = (async () => {
      if (!isSupabaseConfigured || !supabase) {
        initialized.value = true
        return
      }
      const { data, error } = await supabase.auth.getSession()
      if (error) authError.value = error.message
      session.value = data.session
      if (session.value?.user) {
        try {
          await loadContext()
        } catch {
          contextError.value = contextError.value ?? 'Could not load your access.'
        }
      }
      if (!unsubscribe) {
        const { data: listener } = supabase.auth.onAuthStateChange((event, nextSession) => {
          session.value = nextSession
          if (event === 'SIGNED_OUT') {
            clearSessionState()
            return
          }
          if (event === 'SIGNED_IN' && nextSession?.user && nextSession.user.id !== context.value.profile?.id) {
            void loadContext().catch((error: unknown) => {
              contextError.value = error instanceof Error ? error.message : String(error)
            })
          }
        })
        unsubscribe = () => listener.subscription.unsubscribe()
      }
      initialized.value = true
    })()
    return initPromise
  }

  function dispose() {
    unsubscribe?.()
    unsubscribe = null
  }

  watch(activeBranchId, (branchId) => {
    if (!user.value) return
    if (branchId) localStorage.setItem(branchKey(user.value.id), branchId)
  })

  return {
    session,
    context,
    user,
    profile,
    memberships,
    groups,
    shops,
    branches,
    branchesForRole,
    devices,
    activeBranchId,
    activeGroupId: activeGroupIdValue,
    activeBranch,
    activeShop,
    activeShopId,
    activeGroup,
    role,
    isSuperAdmin,
    isOwner,
    canManageShop,
    canManageBranch,
    canViewReports,
    displayName,
    email,
    isAuthenticated,
    initialized,
    loadingContext,
    authError,
    contextError,
    usingCachedContext,
    init,
    signIn,
    signOut,
    loadContext,
    refreshContext,
    setBranch,
    setGroup,
    dispose,
  }
})
