defmodule Electric.Plug.Router do
  use Plug.Router, copy_opts_to_assign: :config

  plug Plug.RequestId
  plug :server_header, Electric.vsn()
  plug :match
  plug Plug.Telemetry, event_prefix: [:electric, :routing]
  plug Plug.Logger
  plug Plug.RequestId
  plug :dispatch

  match "/", via: [:get, :head], do: send_resp(conn, 200, "")

  get "/v1/shape/:root_table", to: Electric.Plug.ServeShapePlug
  delete "/v1/shape/:root_table", to: Electric.Plug.DeleteShapePlug

  match _ do
    send_resp(conn, 404, "Not found")
  end

  def server_header(conn, version) do
    conn
    |> Plug.Conn.put_resp_header("server", "ElectricSQL/#{version}")
  end
end
