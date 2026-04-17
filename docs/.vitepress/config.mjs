export default {
  title: 'ParseBox',
  description: 'Docs and tooling scaffold for Raspberry Pi web projects',
  base: '/ParseBox.rPi/',
  themeConfig: {
    nav: [
      { text: 'Docs', link: '/' },
      { text: 'Getting Started', link: '/guide/getting-started' },
      { text: 'Fresh Pi Setup', link: '/guide/pi-fresh-setup' }
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Fresh Pi Setup (Kiosk Baseline)', link: '/guide/pi-fresh-setup' }
        ]
      }
    ]
  }
}
