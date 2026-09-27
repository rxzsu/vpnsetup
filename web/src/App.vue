<script setup lang="ts">
import { computed } from 'vue'
import { useRoute } from 'vue-router'
import TabBar from './components/TabBar.vue'

const route = useRoute()
const bare = computed(() => route.meta.bare === true)
</script>

<template>
  <div class="min-h-dvh">
    <RouterView />
    <TabBar v-if="!bare" />
  </div>
</template>
