# 🗺️ Roadmap & 📜 Credits

Planned work for Facebook Plus, followed by the provenance and credits for the
project. Contributions and suggestions are welcome — open an issue or a pull
request.

## 🗺️ Roadmap

**Feed & Content**
- [ ] Hide **ads on Facebook Marketplace**

**Downloads**
- [ ] **Multiple-quality** download picker for Reels & videos (choose resolution before saving)

**Navigation**
- [ ] Option to hide the **Reels / Video tab** from the bottom tab bar
- [ ] Remove the **"Also from Meta"** section from the left sidebar

> [!NOTE]
> This list tracks intended work; items are unchecked until shipped in a release.

## 📜 Provenance & Credits

- **Idea & Inspiration:** The core concept of this tweak was inspired by the closed-source Facebook tweak **[Glow](https://github.com/dayanch96/Glow)**. This project is a clean reimplementation based on its behavioral analysis.
- **Story & Reels Downloader:** The media download feature (`src/Features/Downloads/`) was contributed by **[ttlongdl](https://github.com/ttlongdl/Facebook-Plus)** via their GPLv3 fork, and is integrated here with attribution as required by the license.
- **"Open in Facebook" Safari Extension:** The bundled Safari web extension (`OpenInFacebookSafariExtension/`, built from source into the IPA) is our own, independently written implementation — its own `NSExtension` host, manifest and link-routing scripts, with no third-party binary or source bundled. See `OpenInFacebookSafariExtension/README.md` for details.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

This project is distributed under the **[GNU General Public License v3.0](LICENSE)**; see the `LICENSE` file for details.
