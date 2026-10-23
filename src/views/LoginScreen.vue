<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { isSupabaseConfigured } from '../lib/supabase'
import { useAuthStore } from '../stores/auth'

const auth = useAuthStore()
const router = useRouter()
const route = useRoute()
const email = ref('')
const password = ref('')
const showPassword = ref(false)
const error = ref<string | null>(null)
const busy = ref(false)

async function submit() {
  error.value = null
  busy.value = true
  try {
    await auth.signIn(email.value, password.value)
    const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : '/'
    await router.replace(redirect)
  } catch (submitError) {
    if (auth.isAuthenticated) {
      const redirect = typeof route.query.redirect === 'string' ? route.query.redirect : '/'
      await router.replace(redirect)
      return
    }
    error.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="login-layout">
    <section class="login-story">
      <div class="brand large">
        <div class="brand-mark">B</div>
        <div>
          <strong>Benta</strong>
          <span>Business control</span>
        </div>
      </div>
      <div class="login-copy">
        <p class="eyebrow">One clear view of your shop</p>
        <h1>Sales, stock, cash, and profit — without the guesswork.</h1>
        <p>
          A focused point-of-sale for chicken wing shops, built with an offline-safe ledger and controls that keep every
          peso accountable.
        </p>
      </div>
      <ul class="login-points">
        <li><b>01</b><span>Fast branch-level checkout with flavors and exact change.</span></li>
        <li><b>02</b><span>Recipe-based inventory and production in one place.</span></li>
        <li><b>03</b><span>Owner approvals for voids, refunds, and cash movements.</span></li>
      </ul>
      <p class="login-footnote">Made for Philippine food businesses · Asia/Manila business days</p>
    </section>

    <section class="login-panel">
      <div class="login-card">
        <p class="eyebrow">Team access</p>
        <h2>Sign in to your business</h2>
        <p class="subtle">Use the account your owner or super admin invited.</p>

        <div v-if="!isSupabaseConfigured" class="callout warning">
          Supabase is not configured. Add <code>VITE_SUPABASE_URL</code> and
          <code>VITE_SUPABASE_PUBLISHABLE_KEY</code> to <code>.env</code>, then restart the app.
        </div>

        <form v-else class="form-stack login-form" @submit.prevent="submit">
          <label>
            <span>Email address</span>
            <input v-model="email" type="email" autocomplete="email" placeholder="you@business.ph" required />
          </label>
          <label>
            <span>Password</span>
            <div class="password-field">
              <input
                v-model="password"
                :type="showPassword ? 'text' : 'password'"
                autocomplete="current-password"
                placeholder="Your password"
                required
              />
              <button type="button" @click="showPassword = !showPassword">
                {{ showPassword ? 'Hide' : 'Show' }}
              </button>
            </div>
          </label>
          <p v-if="error || auth.authError" class="form-error">{{ error || auth.authError }}</p>
          <button type="submit" class="primary login-submit" :disabled="busy">
            {{ busy ? 'Signing in…' : 'Sign in' }}
          </button>
        </form>

        <p class="login-help">
          Need access? Ask an owner to add your email from <strong>Admin → Team</strong>. First-time setup is handled by
          the super admin.
        </p>
      </div>
    </section>
  </div>
</template>
