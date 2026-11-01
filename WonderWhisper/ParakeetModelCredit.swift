import Foundation

/// CC-BY-4.0 attribution for a model built on others' work.
struct ParakeetModelCredit: Equatable {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    /// One-line attribution chain, base model first.
    let summary: String
    let links: [Link]
    let licenseName: String
    let licenseURL: URL

    static let barkClean = ParakeetModelCredit(
        summary: "Built on NVIDIA Parakeet TDT 0.6B v3, post-trained by Conway Research as "
            + "Underdog Bark 3.0 Clean, converted to Core ML by FluidInference.",
        links: [
            Link(title: "NVIDIA Parakeet TDT 0.6B v3",
                 url: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!),
            Link(title: "Conway Research Underdog Bark 3.0 Clean",
                 url: URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean")!),
            Link(title: "FluidInference Core ML conversion",
                 url: URL(string: "https://huggingface.co/FluidInference/bark-3.0-coreml")!)
        ],
        licenseName: "CC BY 4.0",
        licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    )
}
