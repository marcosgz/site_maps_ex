defmodule SingleSiteWeb.Router do
  use SingleSiteWeb, :router

  scope "/", SingleSiteWeb do
    get "/", SiteController, :home
    get "/about", SiteController, :home
    get "/posts/:slug", SiteController, :post
    get "/robots.txt", SiteController, :robots
  end
end
