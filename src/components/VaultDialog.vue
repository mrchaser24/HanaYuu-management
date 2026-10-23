<script setup lang="ts">
import { computed, ref } from 'vue'
import AppModal from './AppModal.vue'
import { useOfflineStore } from '../stores/offline'

const props = defineProps<{ reason?: string }>()
const emit = defineEmits<{ close: []; ready: [] }>()
const offline = useOfflineStore()

const pin = ref('')
const confirmPin = ref('')
const error = ref<string | null>(null)
const busy = ref(false)
const setup = computed(() => !offline.vaultExists)

async function submit() {
  error.value = null
  if (setup.value && pin.value !== confirmPin.value) {
    error.value = 'The PIN entries do not match.'
    return
  }
  busy.value = true
  try {
    if (setup.value) await offline.setupPin(pin.value)
    else await offline.unlock(pin.value)
    emit('ready')
  } catch (submitError) {
    error.value = submitError instanceof Error ? submitError.message : String(submitError)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AppModal
    :title="setup ? 'Create an offline PIN' : 'Unlock saved sales'"
    :subtitle="
      setup
        ? 'Offline sales are encrypted on this device with a PIN that never leaves your browser.'
        : 'Enter your PIN to decrypt and synchronize sales saved on this device.'
    "
    @close="emit('close')"
  >
    <div v-if="props.reason" class="callout warning">{{ props.reason }}</div>
    <form class="form-stack" @submit.prevent="submit">
      <label>
        <span>{{ setup ? 'New 4–8 digit PIN' : 'PIN' }}</span>
        <input
          v-model="pin"
          type="password"
          inputmode="numeric"
          autocomplete="off"
          maxlength="8"
          pattern="[0-9]*"
          autofocus
          required
        />
      </label>
      <label v-if="setup">
        <span>Confirm PIN</span>
        <input v-model="confirmPin" type="password" inputmode="numeric" autocomplete="off" maxlength="8" required />
      </label>
      <p v-if="error" class="form-error">{{ error }}</p>
      <div class="dialog-actions">
        <button type="button" class="secondary" @click="emit('close')">Cancel</button>
        <button type="submit" class="primary" :disabled="busy || pin.length < 4">
          {{ busy ? 'Working…' : setup ? 'Create PIN' : 'Unlock' }}
        </button>
      </div>
    </form>
  </AppModal>
</template>
