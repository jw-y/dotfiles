return {
    {
        "catppuccin/nvim",
        name = "catppuccin",
        priority = 1000,
        config = {
            flavour = "mocha",
            transparent_background = false,
            color_overrides = {
				mocha = {
					base = "#101016", -- "#000000",
					mantle = "#000000",
					--crust = "#000000",
				},
			},
        }
    },
}
