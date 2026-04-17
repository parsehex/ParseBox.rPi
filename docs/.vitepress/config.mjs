export default {
  title: 'ParseBox',
  description: 'Docs and tooling scaffold for Raspberry Pi web projects',
  base: '/ParseBox.rPi/',
  themeConfig: {
    nav: [
      { text: 'Docs', link: '/' },
      { text: 'Getting Started', link: '/guide/getting-started' },
      { text: 'Kiosk', link: '/kiosk' }
    ],
    sidebar: [
      {
        text: 'Guides',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Kiosk Mode', link: '/kiosk' }
        ]
      }
    ]
  }
}
