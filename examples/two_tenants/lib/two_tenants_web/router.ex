defmodule TwoTenantsWeb.Router do
  use TwoTenantsWeb, :router

  pipeline :site do
    plug TwoTenantsWeb.Plugs.Tenant
  end

  scope "/", TwoTenantsWeb do
    pipe_through :site

    get "/", SiteController, :home
    get "/about", SiteController, :home
    get "/posts/:slug", SiteController, :post
    get "/robots.txt", SiteController, :robots
  end
end
