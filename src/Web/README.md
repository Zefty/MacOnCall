# MacOnCall web

A small dark landing page inspired by the supplied MacBook reference. Plain HTML and CSS, system fonts, bundled Phosphor icons, and a small JavaScript module for accessible mode tabs and scroll reveals. No external services. Vite is used only for local development and building.

## Local development

Requires Node.js 22.12+ (or a current LTS release).

```sh
cd src/Web
npm ci
npm run dev
```

## Build and host

```sh
npm run build
npm run preview
```

Configure your static host with:

- **Project root:** `src/Web`
- **Install command:** `npm ci`
- **Build command:** `npm run build`
- **Publish directory:** `dist`

The build uses relative asset URLs, so it also works under a subdirectory (including GitHub Pages). No server, environment variables, or SPA rewrites are required.

Edit copy and GitHub links in `index.html`, and styles in `style.css`. The download button points to the latest GitHub release, where visitors can download the DMG. Assets in `public/assets` are copied from the app icon under `src/MacOnCall` and `docs/automatic.png`; refresh them when the app UI changes.

The page uses the requested dark theme. The hero includes a responsive CSS Mac display, blue edge glow, and a clearly labelled illustration of the app's actual Automatic controls. Hero content enters in sequence, sections reveal once on scroll, and the mode selector switches between animated Automatic and Manual product demos with vertical timelines. Reduced motion is honoured, including live preference changes. Tabs support arrow keys, Home, and End. FAQ disclosures and both workflows remain readable without JavaScript. Edit the interaction logic in `main.js`.

The short release note reflects the native app's documented limitations; persistence and recovery should not be described as a guarantee against all macOS forced-sleep behaviour.
