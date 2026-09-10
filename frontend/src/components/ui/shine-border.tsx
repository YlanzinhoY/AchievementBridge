import { type ParentComponent, mergeProps } from 'solid-js'

import { cn } from '@/lib/utils'

export interface ShineBorderProps {
  borderRadius?: number
  borderWidth?: number
  class?: string
  color?: string | string[]
  duration?: number
}

export const ShineBorder: ParentComponent<ShineBorderProps> = (props) => {
  const localProps = mergeProps(
    { borderRadius: 8, borderWidth: 1, color: '#a277ff', duration: 12 },
    props,
  )

  return (
    <div
      style={{ '--border-radius': `${localProps.borderRadius}px` }}
      class={cn('shine-border', localProps.class)}
    >
      <div
        aria-hidden="true"
        style={{
          '--border-width': `${localProps.borderWidth}px`,
          '--border-radius': `${localProps.borderRadius}px`,
          '--duration': `${localProps.duration}s`,
          '--mask-linear-gradient':
            'linear-gradient(#fff 0 0) content-box, linear-gradient(#fff 0 0)',
          '--background-radial-gradient': `radial-gradient(transparent, transparent, ${
            Array.isArray(localProps.color)
              ? localProps.color.join(', ')
              : localProps.color
          }, transparent, transparent)`,
        }}
        class="shine-border__effect"
      />
      {localProps.children}
    </div>
  )
}
