# Contributing to Shastra

Thanks for helping build Shastra. Start with the [README](README.md) for setup and current limits, and [BUILD_PLAN.md](BUILD_PLAN.md) for the implementation roadmap.

For bugs, open an issue with the macOS version, provider and CLI version, steps to reproduce, and expected versus actual behavior. Remove credentials and private conversation content from logs. For larger changes, open an issue to discuss the scope first.

Fork the repository, create a branch, and keep pull requests focused. Explain the behavior changed and how you verified it. For application changes, run the relevant checks:

```sh
(cd Bridge/Claude && npm ci --ignore-scripts --no-audit --no-fund)
swift build
zsh Scripts/test.sh
swift run ShastraSelfTest
(cd Bridge/Claude && npm test)
```

Live provider tests require a logged-in vendor CLI and may create sessions. Use them only when relevant to your change.

## Website

The GitHub Pages website lives in `website/`. It uses plain HTML and CSS, without a build step. Preview with `python3 -m http.server 8080 --directory website`, then open `http://localhost:8080`. Check desktop and mobile layouts, keyboard navigation, and links before submitting. Changes merged to `main` deploy through `.github/workflows/pages.yml`.

## License

Contributions are provided under the project's [MIT license](LICENSE). Third-party dependencies retain their own licenses.
