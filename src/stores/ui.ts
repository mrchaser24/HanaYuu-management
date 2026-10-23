import { ref } from 'vue'
import { defineStore } from 'pinia'

export type ToastTone = 'success' | 'error' | 'info' | 'warning'

export interface ToastMessage {
  id: number
  title: string
  detail?: string
  tone: ToastTone
}

let nextId = 1

export const useUiStore = defineStore('ui', () => {
  const toasts = ref<ToastMessage[]>([])
  const online = ref(typeof navigator === 'undefined' ? true : navigator.onLine)

  function notify(title: string, detail?: string, tone: ToastTone = 'info') {
    const id = nextId++
    toasts.value.push({ id, title, detail, tone })
    window.setTimeout(() => dismiss(id), tone === 'error' ? 7000 : 4200)
  }

  function success(title: string, detail?: string) {
    notify(title, detail, 'success')
  }

  function error(title: string, detail?: string) {
    notify(title, detail, 'error')
  }

  function dismiss(id: number) {
    toasts.value = toasts.value.filter((toast) => toast.id !== id)
  }

  function setOnline(value: boolean) {
    online.value = value
  }

  return { toasts, online, notify, success, error, dismiss, setOnline }
})
