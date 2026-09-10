export interface NavbarProps {
  logsHref?: string
}

function Navbar(props: NavbarProps) {
  return (
    <header class="sticky top-0 z-50 w-full border-b border-primary/25 bg-background/90 backdrop-blur-md">
      <nav
        aria-label="Navegação principal"
        class="mx-auto flex h-20 w-full max-w-7xl items-center justify-between px-4 sm:px-6 lg:px-8"
      >
        <a
          href="/"
          aria-label="Achievement Bridge — início"
          class="rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        >
          <span class="text-xl font-semibold tracking-tight sm:text-2xl">Bridge</span>
        </a>

        <a
          href={props.logsHref ?? '/bridge-logs'}
          class="inline-flex h-10 items-center justify-center rounded-md border border-primary/35 bg-primary/10 px-4 text-sm font-medium text-primary shadow-sm transition-colors hover:bg-primary hover:text-primary-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
        >
          Bridge logs
        </a>
      </nav>
    </header>
  )
}

export default Navbar
