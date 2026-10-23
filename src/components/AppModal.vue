<script setup lang="ts">
import { onBeforeUnmount, onMounted } from 'vue'

defineProps<{ title: string; subtitle?: string; wide?: boolean }>()
const emit = defineEmits<{ close: [] }>()

function onKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') emit('close')
}

onMounted(() => {
  document.addEventListener('keydown', onKeydown)
  document.body.classList.add('modal-open')
})

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown)
  document.body.classList.remove('modal-open')
})
</script>

<template>
  <Teleport to="body">
    <div class="modal-backdrop" @click.self="emit('close')">
      <section class="modal-card" :class="{ wide }" role="dialog" aria-modal="true" :aria-label="title">
        <header class="modal-head">
          <div>
            <p class="eyebrow">Benta</p>
            <h2>{{ title }}</h2>
            <p v-if="subtitle" class="subtle">{{ subtitle }}</p>
          </div>
          <button type="button" class="icon-button" aria-label="Close dialog" @click="emit('close')">×</button>
        </header>
        <div class="modal-body">
          <slot />
        </div>
        <footer v-if="$slots.footer" class="modal-footer">
          <slot name="footer" />
        </footer>
      </section>
    </div>
  </Teleport>
</template>
