import { BridgeCards } from '@/components/cards'
import Navbar from '@/components/layout/Navbar'
import TechStack from '@/components/tech-stack'

function App() {
  return (
    <div class="min-h-svh bg-background text-foreground">
      <Navbar />
      <main id="app" class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6 lg:px-8" />

      <div>
        <BridgeCards />
      </div>

      <TechStack />

    </div>



  )
}

export default App
